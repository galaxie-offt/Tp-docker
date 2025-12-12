# TLS / HTTPS avec Traefik

## Objectif

Mettre en place un certificat TLS auto-signé pour sécuriser l'accès à l'application via `https://app.localhost` et `https://monitoring.localhost`.

## Génération du certificat auto-signé

Commande utilisée sur la VM (dans le dossier du projet) :

```bash
mkdir -p traefik/certs

openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout traefik/certs/app.localhost.key \
  -out traefik/certs/app.localhost.crt \
  -subj "/CN=app.localhost"
```

### Détails de la commande :

- `req` : Crée une demande de certificat X.509
- `-x509` : Produit un certificat auto-signé au lieu d'une demande de signature
- `-nodes` : N'encrypte pas la clé privée
- `-days 365` : Valide le certificat pendant 365 jours
- `-newkey rsa:2048` : Génère une nouvelle clé RSA de 2048 bits
- `-keyout` : Spécifie le fichier de sortie de la clé privée
- `-out` : Spécifie le fichier de sortie du certificat
- `-subj` : Remplit les champs du sujet sans prompt interactif

### Fichiers générés :

- `traefik/certs/app.localhost.crt` : Certificat X.509 au format PEM
- `traefik/certs/app.localhost.key` : Clé privée RSA 2048 bits au format PEM

## Emplacement et montage des certificats

Les fichiers sont stockés dans le répertoire du projet :

```
traefik/
└── certs/
    ├── app.localhost.crt
    └── app.localhost.key
```

Ils sont montés dans le conteneur Traefik via `compose.yml` :

```yaml
  traefik:
    image: traefik:v3.1
    volumes:
      - ./traefik/traefik.yml:/traefik.yml:ro
      - ./traefik/dynamic.yml:/dynamic.yml:ro
      - ./traefik/certs:/certs:ro
```

La flag `:ro` signifie "read-only" (lecture seule).

### Configuration Traefik (traefik/dynamic.yml)

```yaml
tls:
  certificates:
    - certFile: "/certs/app.localhost.crt"
      keyFile: "/certs/app.localhost.key"
```

Traefik charge ce fichier et associe le certificat aux routers TLS configurés.

## Fonctionnement du router TLS Traefik

### Entrypoints (ports d'entrée)

Traefik expose deux entrypoints configurés dans `traefik/traefik.yml` :

```yaml
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
```

- `web` : écoute sur le port 80 (HTTP)
- `websecure` : écoute sur le port 443 (HTTPS)

### Redirection HTTP → HTTPS globale

Labels appliqués au service `traefik` lui-même pour rediriger tout HTTP vers HTTPS :

```yaml
  traefik:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.http-catchall.rule=HostRegexp(`{host:.+}`)"
      - "traefik.http.routers.http-catchall.entrypoints=web"
      - "traefik.http.routers.http-catchall.middlewares=redirect-to-https"
      - "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
      - "traefik.http.middlewares.redirect-to-https.redirectscheme.permanent=true"
```

Fonctionnement :
- `HostRegexp` capture tous les hosts
- `entrypoints=web` signifie "applique sur le port 80"
- Le middleware `redirect-to-https` change le schéma de `http://` à `https://`
- `permanent=true` envoie un code 301 (redirection permanente)

Résultat : `http://app.localhost` → `https://app.localhost` (code 301)

### Router TLS pour l'application Flask

```yaml
  app:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app.rule=Host(`app.localhost`)"
      - "traefik.http.routers.app.entrypoints=websecure"
      - "traefik.http.routers.app.tls=true"
      - "traefik.http.services.app.loadbalancer.server.port=5000"
      - "traefik.docker.network=tp-networks_secure_front"
```

Fonctionnement :
- `rule=Host(...)` : Route le trafic uniquement si le domaine est `app.localhost`
- `entrypoints=websecure` : Écoute sur le port 443 (HTTPS)
- `tls=true` : Active TLS pour ce router
- `server.port=5000` : Traefik envoie le trafic au port 5000 du conteneur `app`
- `docker.network` : Force Traefik à utiliser le réseau `secure_front`

### Router TLS pour Grafana

```yaml
  grafana:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(`monitoring.localhost`)"
      - "traefik.http.routers.grafana.entrypoints=websecure"
      - "traefik.http.routers.grafana.tls=true"
      - "traefik.http.services.grafana.loadbalancer.server.port=3000"
      - "traefik.docker.network=tp-networks_secure_front"
```

Même principe que l'app, mais avec le domaine `monitoring.localhost` et le port 3000.

## Flux de requête HTTPS complet

1. Utilisateur visite `https://app.localhost` dans le navigateur
2. Traefik reçoit la connexion TLS sur le port 443
3. Traefik présente le certificat `app.localhost.crt` au client
4. Le navigateur détecte que c'est un certificat auto-signé et affiche un avertissement
5. L'utilisateur accepte l'avertissement (ou ajoute une exception)
6. La connexion TLS est établie
7. Traefik route la requête HTTP vers `app:5000` (Port interne)
8. Flask répond
9. La réponse retourne via Traefik au navigateur

## Vérification de la configuration

Pour vérifier que le certificat est bien utilisé :

```bash
# Voir les détails du certificat
openssl x509 -in traefik/certs/app.localhost.crt -text -noout

# Tester la connexion TLS (depuis la VM ou machine distante)
openssl s_client -connect app.localhost:443 -showcerts

# Depuis le navigateur : cliquer sur le cadenas → Certificat
# Doit afficher : Common Name = app.localhost, auto-signé
```

## Différence entre HTTP et HTTPS dans ce setup

| Aspect | HTTP | HTTPS |
|--------|------|-------|
| Port | 80 | 443 |
| Chiffrement | Non | Oui (TLS) |
| Redirection | Automatique vers HTTPS | - |
| Certificat | N/A | Auto-signé (app.localhost) |
| Domaine | Tous | Spécifique |

## Notes importantes

1. **Auto-signé** : Le certificat ne vient pas d'une autorité de certification (CA) reconnue. C'est normal pour le développement/TP.
2. **Avertissement navigateur** : C'est attendu et souhaitable (preuve que le TLS fonctionne).
3. **IP directe non supportée** : `https://10.5.0.9:443` ne fonctionnera pas car le certificat est pour le domaine `app.localhost`, pas pour l'IP.
4. **Validité 365 jours** : Le certificat doit être régénéré après 1 an.

Pour plus de sécurité en production, on utiliserait des certificats signés par une CA (ex: Let's Encrypt avec Traefik).
