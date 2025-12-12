# Docker Compose - Infrastructure Complète avec Traefik, Monitoring et Registry

Ce projet déploie une infrastructure Docker complète avec :
- **Proxy inversé HTTPS** via Traefik avec certificats auto-signés
- **Application Flask** connectée à une base de données MariaDB
- **Observabilité complète** (Prometheus + Grafana + cAdvisor)
- **Registry Docker privée** pour le CI/CD
- **Sécurité réseau avancée** avec isolation des réseaux et règles iptables

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Internet (HTTPS)                         │
│                     https://app.localhost                         │
│                  https://monitoring.localhost                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                    ┌───────▼────────┐
                    │   Traefik      │
                    │  (Port 80/443) │
                    └───┬──────────┬─┘
                        │          │
         ┌──────────────┘          └─────────────────┐
         │                                           │
    ┌────▼────────┐              ┌─────────────────▼──────┐
    │secure_front │              │   monitoring_net       │
    │   Network   │              │      Network          │
    └────┬────────┘              └──────┬─────────┬──────┘
         │                              │         │
    ┌────▼─────┐          ┌────────────▼┐  ┌────▼───────┐
    │   App    │          │  Prometheus │  │  cAdvisor  │
    │  (Flask) │          │   (TSDb)    │  │  (Metrics) │
    └────┬─────┘          └────────────┬┘  └────┬───────┘
         │                              │        │
    ┌────▼──────────────────────────────▼────────▼──┐
    │          secure_back Network                   │
    │  ┌──────────────┐      ┌──────────────────┐  │
    │  │   MariaDB    │      │  Registry:5000   │  │
    │  │   (Database) │      │  (Docker Images) │  │
    │  └──────────────┘      └──────────────────┘  │
    └───────────────────────────────────────────────┘
```

## Structure du Projet

```
tp-networks/
├── compose.yml                 # Configuration Docker Compose (tous les services)
├── build.sh                    # Script CI/CD (build → tag → push → redeploy)
├── init-firewall.sh           # Règles iptables pour la DB
│
├── app/
│   ├── Dockerfile             # Image Flask (Python 3.11-slim)
│   ├── entrypoint.sh          # Script d'entrypoint (bloque ICMP)
│   └── app.py                 # Application Flask
│
├── traefik/
│   ├── traefik.yml            # Configuration Traefik (entrypoints, providers)
│   ├── dynamic.yml            # Config TLS dynamique
│   └── certs/
│       ├── app.localhost.crt  # Certificat auto-signé
│       └── app.localhost.key  # Clé privée
│
├── prometheus/
│   └── prometheus.yml         # Configuration Prometheus (scrape jobs)
│
├── README.md                  # Ce fichier
├── tls.md                     # Documentation TLS
├── cicd.md                    # Documentation CI/CD
└── security.md                # Documentation Sécurité
```

## Installation et Démarrage

### Prérequis

- Docker (v20.10+)
- Docker Compose (v2.0+)
- Debian/Linux (testé sur Debian 10.5.0.9)

### Étape 1 : Générer les certificats TLS auto-signés

```bash
mkdir -p traefik/certs

openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout traefik/certs/app.localhost.key \
  -out traefik/certs/app.localhost.crt \
  -subj "/CN=app.localhost"
```

Cela génère :
- `traefik/certs/app.localhost.crt` : Certificat X.509
- `traefik/certs/app.localhost.key` : Clé privée RSA 2048-bit

### Étape 2 : Démarrer les services

```bash
docker compose up -d
```

Vérifier que tous les services sont "Up" :
```bash
docker compose ps
```

### Étape 3 : Configurer l'accès depuis ta machine

Sur **ta machine de test** (PC/Mac), ajoute ces entrées à `/etc/hosts` (ou `C:\Windows\System32\drivers\etc\hosts` sur Windows) :

```
10.5.0.9 app.localhost monitoring.localhost
```

Remplace `10.5.0.9` par l'IP réelle de ta VM Debian.

## Accès aux Services

| Service | URL | Login | Certificat |
|---------|-----|-------|-----------|
| **Application Flask** | `https://app.localhost` | N/A | Auto-signé |
| **Grafana** | `https://monitoring.localhost` | `adminuser` / `adminpass` | Auto-signé |
| **HTTP Redirect** | `http://app.localhost` | N/A | → HTTPS |
| **Registry Docker** | `localhost:5000` | (interne Docker) | HTTP local |

**Note** : Les certificats auto-signés déclencheront un avertissement dans ton navigateur. C'est normal pour un environnement de développement/TP.

## Services Déployés

### 1. Traefik (Reverse Proxy HTTPS)

**Image** : `traefik:v3.1`

**Rôle** : Routeur HTTP/HTTPS principal
- Écoute sur les ports 80 et 443
- Redirige HTTP → HTTPS automatiquement
- Charge le certificat auto-signé depuis `traefik/certs/`
- Découvre automatiquement les services via Docker labels

**Configuration** : `traefik/traefik.yml` et `traefik/dynamic.yml`

### 2. Application Flask

**Image** : `localhost:5000/app:latest` (à partir de la registry locale)

**Rôle** : Serveur web backend
- Écoute sur le port 5000 (interne)
- Connecté à MariaDB
- Exécute un script `entrypoint.sh` qui bloque le ping ICMP
- Accessible via Traefik sur `https://app.localhost`

**Réseaux** : `secure_back` (DB) et `secure_front` (Traefik)

### 3. MariaDB

**Image** : `mariadb:latest`

**Rôle** : Base de données relationnelle
- Crée une base `appdb` avec utilisateur `appuser`
- Exécute les règles iptables depuis `init-firewall.sh`
- **Non exposée** à l'extérieur (réseau `secure_back` uniquement)

**Credentials** :
- Root : `rootpass`
- User : `appuser` / `apppass`
- Database : `appdb`

### 4. Registry Docker

**Image** : `registry:2`

**Rôle** : Stockage d'images Docker privé
- Écoute sur le port 5000 (accès local uniquement)
- Stocke les images construites localement
- Utilisé par le script `build.sh` pour le CI/CD

### 5. cAdvisor

**Image** : `gcr.io/cadvisor/cadvisor:latest`

**Rôle** : Collecteur de métriques conteneur
- Collecte CPU, RAM, Disk I/O, Uptime de tous les conteneurs
- Expose les métriques sur le port 8080
- **Non exposé** directement (réseau `monitoring_net` uniquement)
- Scraped par Prometheus

### 6. Prometheus

**Image** : `prom/prometheus:latest`

**Rôle** : Série temporelle (Time Series Database)
- Scrape cAdvisor toutes les 15 secondes
- Stocke les métriques pour requêtes ultérieures
- **Non exposé** à l'extérieur
- Utilisé par Grafana pour les dashboards

**Configuration** : `prometheus/prometheus.yml`

### 7. Grafana

**Image** : `grafana/grafana:latest`

**Rôle** : Plateforme de visualisation
- Dashboard pour visualiser CPU, RAM, Disk I/O, Uptime
- Accessible via Traefik sur `https://monitoring.localhost`
- Login : `adminuser` / `adminpass`

**Datasource** : Prometheus (`http://prometheus:9090`)

## Sécurité Réseau

### Réseaux Docker

Trois réseaux isolés :

1. **secure_front** (172.30.1.0/24)
   - Traefik
   - App (pour l'accès depuis Traefik)
   - Grafana (pour l'accès depuis Traefik)

2. **secure_back** (172.30.0.0/24)
   - App
   - MariaDB
   - Registry
   - Firewall iptables bloque le trafic inter-réseaux

3. **monitoring_net** (172.30.2.0/24)
   - cAdvisor
   - Prometheus
   - Grafana

**Isolation** :
- MariaDB n'est accessible que depuis App (même sous-réseau)
- Prometheus n'est pas exposé à l'extérieur
- Registry n'est accessible qu'en local
- Aucun trafic direct entre réseaux sans passer par Traefik

### Règles iptables

#### MariaDB (init-firewall.sh)

```bash
# Bloque les gateways Docker
iptables -A INPUT -s 172.30.0.1 -j DROP
iptables -A INPUT -s 172.30.1.1 -j DROP

# Accepte le trafic depuis secure_back (DB)
iptables -A INPUT -s 172.30.0.0/24 -j ACCEPT

# Accepte les connexions établies
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
```

#### App (entrypoint.sh)

```bash
# Bloque le ping ICMP
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
```

### Droits Conteneur

- MariaDB : `cap_add: NET_ADMIN` (pour exécuter iptables)
- App : `cap_add: NET_ADMIN` (pour exécuter iptables dans entrypoint.sh)

## TLS (HTTPS)

### Certificat Auto-signé

Généré avec OpenSSL (voir Étape 1 ci-dessus) :
- **Domaine** : `app.localhost`
- **Valide** : 365 jours
- **Algorithme** : RSA 2048-bit
- **Format** : X.509 self-signed

### Configuration Traefik

**Router HTTPS** (défini dans `compose.yml` via labels) :
```yaml
- "traefik.http.routers.app.rule=Host(`app.localhost`)"
- "traefik.http.routers.app.entrypoints=websecure"
- "traefik.http.routers.app.tls=true"
```

**Redirection HTTP → HTTPS** (globale) :
```yaml
- "traefik.http.routers.http-catchall.middlewares=redirect-to-https"
- "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
```

**Fichier dynamique TLS** (`traefik/dynamic.yml`) :
```yaml
tls:
  certificates:
    - certFile: "/certs/app.localhost.crt"
      keyFile: "/certs/app.localhost.key"
```

Pour plus de détails, voir `tls.md`.

## Observabilité

### Métriques cAdvisor

cAdvisor expose les métriques Prometheus suivantes :

```
container_cpu_usage_seconds_total     # CPU total en secondes
container_memory_usage_bytes           # RAM utilisée (bytes)
container_fs_reads_bytes_total         # Total I/O en lecture
container_fs_writes_bytes_total        # Total I/O en écriture
container_start_time_seconds           # Timestamp de démarrage
```

### Dashboard Grafana

Le fichier `grafana-dashboard.json` contient 4 panels :

1. **CPU Usage per Container** : Courbe CPU (5 min rolling)
2. **Memory Usage per Container** : Courbe RAM en temps réel
3. **Disk I/O per Container** : Lectures/écritures (5 min rolling)
4. **Container Uptime** : Temps depuis démarrage (gauge)

**Import** :
1. Va dans Grafana → Dashboards → Import
2. Colle le JSON ou upload `grafana-dashboard.json`
3. Sélectionne Prometheus comme datasource
4. Clique Import

### Objet "lasagna"

Pour le TP, l'objet `lasagna` a été ajouté au début du JSON du dashboard avec des propriétés fictives :

```json
"lasagna": {
  "uptime_fake": "987654",
  "description": "fake uptime data for TP requirement",
  "unit": "seconds",
  "random_property_1": "mozzarella",
  "random_property_2": 42
}
```

## CI/CD avec Registry Privée

### Script build.sh

Automatise le pipeline de build/push/redeploy :

```bash
./build.sh
```

**Étapes** :
1. Build l'image Flask depuis `app/Dockerfile`
2. Tag avec `localhost:5000/app:latest`
3. Push vers la registry locale
4. Stop les conteneurs
5. Relance les services avec la nouvelle image

**Détails** : voir `cicd.md`

### Commandes manuelles

```bash
# Build l'image
docker build -t localhost:5000/app:latest ./app

# Push vers la registry
docker push localhost:5000/app:latest

# Redémarrage
docker compose down
docker compose up -d
```

## Logs et Débogage

### Voir les logs d'un service

```bash
# Tous les services
docker compose logs -f

# Un service spécifique
docker compose logs -f app
docker compose logs -f traefik
docker compose logs -f grafana
docker compose logs -f prometheus
```

### Vérifier le statut

```bash
docker compose ps
```

### Résoudre "Gateway Timeout"

Si tu as un 504 sur `https://monitoring.localhost` :

```bash
# Vérifie que Grafana est UP
docker compose ps grafana

# Vérifie l'isolation réseau
docker network inspect tp-networks_secure_front

# Force le redémarrage de Traefik et Grafana
docker compose stop traefik grafana
docker compose rm -f traefik grafana
docker compose up -d traefik grafana
```

### Test de connexion à la base de données

```bash
# Depuis le conteneur App
docker compose exec app python -c "
import pymysql
conn = pymysql.connect(
    host='db',
    user='appuser',
    password='apppass',
    database='appdb'
)
print('✅ Connected to DB')
conn.close()
"
```

## Scan de Vulnérabilités

Pour scanner les images avec `trivy` :

```bash
# Installer trivy (sur la VM)
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

# Scanner l'image de l'app
trivy image localhost:5000/app:latest
```

Pour plus de détails, voir `security.md`.

## Variables d'Environnement

### MariaDB

```yaml
MYSQL_ROOT_PASSWORD: rootpass
MYSQL_DATABASE: appdb
MYSQL_USER: appuser
MYSQL_PASSWORD: apppass
```

### Grafana

```yaml
GF_SECURITY_ADMIN_USER: adminuser
GF_SECURITY_ADMIN_PASSWORD: adminpass
```

### Flask (app.py)

```python
DB_HOST: db             # Hostname du conteneur
DB_USER: appuser
DB_PASS: apppass
DB_NAME: appdb
```

## Fichiers de Documentation

- **tls.md** : Détails sur la génération et configuration TLS
- **cicd.md** : Pipeline de build et déploiement
- **security.md** : Analyse de sécurité et scan de vulnérabilités

## Dépannage

### Issue : Application Flask retourne 502 Bad Gateway

**Cause** : Flask n'écoute pas sur toutes les interfaces (`0.0.0.0`)

**Solution** : Vérifie que `app.py` a cette ligne :
```python
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
```

### Issue : Grafana ne se connecte pas à Prometheus

**Cause** : Datasource mal configurée ou Prometheus non accessible

**Solution** :
1. Dans Grafana, va dans Configuration → Data Sources
2. Ajoute une nouvelle source Prometheus
3. URL : `http://prometheus:9090`
4. Click "Save & Test"

### Issue : Images Docker ne se buildent pas

**Cause** : Dockerfile incorrect ou missing dependencies

**Solution** :
```bash
docker build --no-cache ./app
docker logs <container_id>
```

## Ports

| Service | Port | Exposé | Accès |
|---------|------|--------|-------|
| Traefik HTTP | 80 | ✅ Oui | Internet |
| Traefik HTTPS | 443 | ✅ Oui | Internet |
| Flask | 5000 | ❌ Non | Traefik uniquement |
| MariaDB | 3306 | ❌ Non | `secure_back` uniquement |
| Registry | 5000 | ✅ Oui | Local Docker |
| cAdvisor | 8080 | ❌ Non | `monitoring_net` uniquement |
| Prometheus | 9090 | ❌ Non | `monitoring_net` uniquement |
| Grafana | 3000 | ❌ Non | Traefik uniquement |

## Volumes

Les données persistes dans des **named volumes** Docker :

- `registry-data` : Images stockées dans la registry
- `prometheus-data` : Métriques Prometheus (TSDB)
- `grafana-data` : Configuration et dashboards Grafana

Pour nettoyer tous les volumes :
```bash
docker compose down -v
```

## Performance et Optimisation

### Scrape Interval

Par défaut, Prometheus scrape cAdvisor toutes les 15 secondes. Pour augmenter la fréquence :

**`prometheus/prometheus.yml`** :
```yaml
global:
  scrape_interval: 5s  # Augmente la résolution
```

Puis redémarrer :
```bash
docker compose up -d --force-recreate prometheus
```

### Rétention des Données

Prometheus garde les données 15 jours par défaut. Pour augmenter :

**`compose.yml`** (service prometheus) :
```yaml
command:
  - "--storage.tsdb.retention.time=30d"  # Conserve 30 jours
```

## Nettoyage Complet

Arrêter et supprimer tous les conteneurs et volumes :

```bash
docker compose down -v
rm -rf traefik/certs/*
rm -rf prometheus/data
rm -rf grafana/data
```

## Ressources Additionnelles

- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [cAdvisor GitHub](https://github.com/google/cadvisor)
- [Docker Registry Documentation](https://docs.docker.com/registry/)

## Licence

MIT

---

**Dernier mise à jour** : Décembre 2025

Pour toute question, consulte les fichiers `tls.md`, `cicd.md`, ou `security.md`.
