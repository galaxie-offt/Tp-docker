# Sécurité Réseau et Durcissement

## Objectif

Renforcer la sécurité de l'infrastructure Docker en :
- Isolant les services sur plusieurs réseaux Docker distincts
- Limitant l'accès aux bases de données et services internes
- Appliquant des règles iptables au niveau des conteneurs
- Scannant les images pour détecter les vulnérabilités

## 1. Réseaux Docker créés

Trois réseaux isolés sont utilisés pour segmenter le trafic :

### secure_front (172.30.1.0/24)

```yaml
  secure_front:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.1.0/24
```

**Conteneurs** :
- `traefik` (172.30.1.2)
- `app` (172.30.1.4)
- `grafana` (172.30.1.3)

**Rôle** : Exposition HTTPS vers l'extérieur via Traefik
- C'est le "frontend" accessible de l'internet
- Tous les services ici sont exposés via reverse proxy

### secure_back (172.30.0.0/24)

```yaml
  secure_back:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/24
```

**Conteneurs** :
- `app` (172.30.0.2)
- `db` (172.30.0.3)
- `registry` (172.30.0.4)

**Rôle** : Réseau interne pour base de données et registry
- Non exposé à l'internet
- Accès au reste de l'infrastructure très restreint
- La base de données MariaDB n'accepte que des connexions de ce réseau

### monitoring_net (172.30.2.0/24)

```yaml
  monitoring_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.2.0/24
```

**Conteneurs** :
- `cadvisor` (172.30.2.2)
- `prometheus` (172.30.2.3)
- `grafana` (172.30.2.4)

**Rôle** : Réseau de monitoring isolé
- Non exposé à l'extérieur
- Grafana se connecte à Prometheus via ce réseau
- Prometheus collecte les métriques de cAdvisor
- Aucun autre service n'a accès à ce réseau

## 2. Isolation et restrictions d'accès

### Qui peut parler à qui ?

```
INTERNET
    │
    ▼
┌─────────────────────────┐
│   Traefik (frontend)    │ ◄── Port 80, 443 exposés
│  (secure_front)         │
└──────┬───────┬──────────┘
       │       │
       ▼       ▼
    APP    GRAFANA
  (secure_front + secure_back)  (secure_front + monitoring_net)
       │
       ▼
    ┌────────────┐
    │  MariaDB   │ ◄── Uniquement de secure_back
    │ (DB only)  │
    └────────────┘

PROMETHEUS + cADVISOR (monitoring_net)
    │
    ▼
  (Isolés, pas d'accès externe)
```

### Règles d'isolation

| De | Vers | Autorisé? | Raison |
|----|------|-----------|--------|
| Internet | Traefik (80/443) | ✅ OUI | Point d'entrée |
| Traefik | App (5000) | ✅ OUI | Via secure_front |
| App | MariaDB (3306) | ✅ OUI | Même réseau (secure_back) |
| Internet | MariaDB | ❌ NON | Port non exposé |
| Internet | Prometheus | ❌ NON | Pas de port exposé |
| Traefik | Prometheus | ❌ NON | Réseaux différents |
| cAdvisor | App | ❌ NON | Réseaux différents |
| App | Grafana (3000) | ❌ NON | Accès via Traefik uniquement |

### Vérifications

Voir les réseaux et leurs membres :

```bash
docker network inspect tp-networks_secure_front
docker network inspect tp-networks_secure_back
docker network inspect tp-networks_monitoring_net
```

Exemple de sortie pour `secure_front` :

```json
{
  "Containers": {
    "3f5ec351d1d...": {
      "Name": "tp-networks-traefik-1",
      "IPv4Address": "172.30.1.2/24"
    },
    "b4b39bf5818...": {
      "Name": "tp-networks-app-1",
      "IPv4Address": "172.30.1.4/24"
    },
    "0c30efe4b3d...": {
      "Name": "tp-networks-grafana-1",
      "IPv4Address": "172.30.1.3/24"
    }
  }
}
```

## 3. Règles iptables au niveau conteneur

### MariaDB (init-firewall.sh)

Les règles iptables de la base de données durcissent l'accès réseau au niveau du conteneur :

```bash
#!/bin/bash

# Attendre que le conteneur soit complètement démarré
sleep 5

# Vider les règles existantes
iptables -F INPUT

# Politique par défaut : DROP (tout bloquer)
iptables -P INPUT DROP

# Bloquer spécifiquement les gateway Docker
iptables -A INPUT -s 172.30.0.1 -j DROP
iptables -A INPUT -s 172.30.1.1 -j DROP

# Accepter le loopback (localhost)
iptables -A INPUT -i lo -j ACCEPT

# Accepter les connexions depuis secure_back (172.30.0.0/24)
iptables -A INPUT -s 172.30.0.0/24 -j ACCEPT

# Accepter les connexions depuis secure_front (172.30.1.0/24)
iptables -A INPUT -s 172.30.1.0/24 -j ACCEPT

# Accepter les connexions établies et reliées
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
```

#### Explication règle par règle

| Règle | Signification |
|-------|---------------|
| `iptables -P INPUT DROP` | Politique par défaut : rejeter tout (whitelist approach) |
| `-s 172.30.0.1 -j DROP` | Bloquer la gateway du réseau backend |
| `-s 172.30.1.1 -j DROP` | Bloquer la gateway du réseau frontend |
| `-i lo -j ACCEPT` | Autoriser les connexions locales au conteneur |
| `-s 172.30.0.0/24 -j ACCEPT` | Autoriser le réseau backend (App, Registry) |
| `-s 172.30.1.0/24 -j ACCEPT` | Autoriser le réseau frontend (Traefik) |
| `-m state --state ESTABLISHED,RELATED` | Autoriser les réponses aux connexions établies |

#### Effet

- Un conteneur externe ou sur un autre réseau (ex: monitoring_net) qui essaie de joindre MariaDB reçoit un **timeout** ou un **connexion refusée**.
- Le conteneur `app` (même réseau) peut se connecter normalement.
- Les gateways Docker (potentiellement dangereuses) sont explicitement bloquées.

### Application (entrypoint.sh)

Le script d'entrypoint du conteneur Flask ajoute une règle ICMP :

```bash
#!/bin/bash
set -e

# Bloque le ping ICMP dans le conteneur app
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP

# Exécute la commande par défaut
exec "$@"
```

#### Explication

- `-p icmp` : Filtre le protocole ICMP
- `--icmp-type echo-request` : Spécifiquement les requêtes echo (ping)
- `-j DROP` : Rejette les paquets

#### Effet

```bash
# Depuis un autre conteneur
docker compose exec db ping app
# PING app (172.30.0.2) 56(84) bytes of data.
# ^C
# --- app statistics ---
# X packets transmitted, 0 received, 100% packet loss, time Xms

# Le ping timeout (pas de réponse)
```

Le service HTTP reste fonctionnel, mais le conteneur ne répond plus aux `ping`.

### Droits supplémentaires (Capabilities)

Pour permettre aux conteneurs d'exécuter des commandes `iptables`, ils ont besoin de la capability `NET_ADMIN` :

```yaml
  db:
    cap_add:
      - NET_ADMIN
  app:
    cap_add:
      - NET_ADMIN
```

**Important** : Sans cette capability, les conteneurs n'peuvent pas exécuter `iptables` et les scripts échouent silencieusement.

## 4. Scan de vulnérabilités

### Installation de Trivy

```bash
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
```

### Scanner l'image de l'app

```bash
trivy image localhost:5000/app:latest
```

Ou si l'image n'existe pas encore localement :

```bash
trivy image python:3.11-slim
```

### Résultats typiques

```
Total: 25 (CRITICAL: 0, HIGH: 3, MEDIUM: 15, LOW: 7)

CRITICAL (0)

HIGH (3)
  - openssl (1.1.1w): CVE-2024-xxxxx (CVSS: 7.5)
  - curl (7.68.0): CVE-2023-xxxxx (CVSS: 7.2)

MEDIUM (15)
  [...]

LOW (7)
  [...]
```

### Interprétation

- **CRITICAL** : Failles très graves, correction immédiate
- **HIGH** : Failles graves, corriger rapidement
- **MEDIUM** : Failles modérées, planifier une correction
- **LOW** : Failles mineures, correction non urgente

Pour l'app Flask, les vulnérabilités sont généralement dans l'image de base Debian/Python, pas dans le code Flask lui-même.

### Réduire les vulnérabilités

1. **Utiliser `slim` ou `alpine`** : Images minimalistes avec moins de paquets
2. **Mettre à jour régulièrement** : `apt-get update && apt-get upgrade`
3. **Supprimer les paquets inutiles** : Plus petite surface d'attaque
4. **Multi-stage build** : Garder uniquement les paquets de runtime

## 5. Schéma de sécurité global

```
┌──────────────────────────────────────────────────────────┐
│                     INTERNET                              │
│              (Attaquants potentiels)                      │
└─────────────────────────┬────────────────────────────────┘
                          │
                   Port 80/443 (HTTP/HTTPS)
                          │
        ┌─────────────────▼──────────────────┐
        │    Traefik (TLS Termination)       │
        │    - Authentification TLS          │
        │    - Redirection HTTP → HTTPS      │
        │    - Single point d'entrée         │
        └──────────────────┬──────────────────┘
                           │
          ┌────────────────┴──────────────────┐
          │                                   │
     ┌────▼───────────┐            ┌────────▼──────┐
     │   App (Flask)  │            │  Grafana       │
     │  secure_front  │            │ secure_front   │
     │  secure_back   │            │ monitoring_net │
     └────┬───────────┘            └────────────────┘
          │                               │
          │ (iptables: ICMP DROP)         │ (iptables: N/A)
          │                               │
     ┌────▼────────────────────────────────────┐
     │  MariaDB (Database)                      │
     │  secure_back ONLY                        │
     │  iptables: Whitelist 172.30.x.0/24      │
     │  PORT 3306 NOT exposed                   │
     └──────────────────────────────────────────┘

     ┌──────────────────────────────────┐
     │  Monitoring (monitoring_net)      │
     │  - cAdvisor (metrics)             │
     │  - Prometheus (TSDB)              │
     │  - NOT exposed to internet        │
     └──────────────────────────────────┘
```

## 6. Résumé des mesures de sécurité

| Mesure | Bénéfice | Niveau |
|--------|---------|--------|
| Réseaux isolés | Empêche l'accès non autorisé inter-réseaux | Réseau |
| iptables MariaDB | Whitelist des IP autorisées | Conteneur |
| iptables App | Bloque les pings (reconnaissance) | Conteneur |
| TLS/HTTPS | Chiffrement en transit | Transport |
| Single entry point | Réduit la surface d'attaque | Architecture |
| Pas de port exposé (DB, Prometheus) | Attaque impossible | Configuration |
| Scan Trivy | Détecte vulnérabilités connues | Dépendances |

## 7. Test de l'isolation

### Tester la connectivité inter-réseaux

```bash
# Essayer de contacter MariaDB depuis cAdvisor (réseaux différents)
docker compose exec cadvisor ping db
# PING db (172.30.0.3) 56(84) bytes of data.
# ^C
# Timeout (iptables DROP)

# Essayer de contacter MariaDB depuis App (même réseau)
docker compose exec app mysql -h db -u appuser -papppass appdb -e "SELECT 1"
# 1
# Connexion réussie
```

### Tester le blocage ICMP

```bash
# App ne répond pas au ping
docker compose exec db ping app
# PING app (172.30.0.2) 56(84) bytes of data.
# ^C
# 100% packet loss (iptables DROP ICMP)

# Mais le service HTTP est accessible
docker compose exec db curl -s http://app:5000/
# Hello from app!
```

### Vérifier les règles iptables en place

```bash
# À l'intérieur du conteneur db
docker compose exec db iptables -L -n

# À l'intérieur du conteneur app
docker compose exec app iptables -L -n
```

## 8. Défense en profondeur

Cette infrastructure applique le concept de **défense en profondeur** :

1. **Couche 1 (Périmètre)** : Seul Traefik exposé, HTTPS obligatoire
2. **Couche 2 (Réseau)** : 3 réseaux Docker isolés
3. **Couche 3 (Hôte)** : Iptables dans les conteneurs
4. **Couche 4 (Application)** : Code Flask utilisant des variables d'environnement (pas de hardcoding)
5. **Couche 5 (Images)** : Scan Trivy des dépendances

Une attaque doit contourner plusieurs couches, ce qui réduit significativement le risque.

## Ressources

- [Docker Network Security](https://docs.docker.com/network/network-security/)
- [iptables Manual](https://linux.die.net/man/8/iptables)
- [Trivy GitHub](https://github.com/aquasecurity/trivy)
- [OWASP Container Security](https://owasp.org/www-community/attacks/)
