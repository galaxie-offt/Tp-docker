# CI/CD Docker avec Registry Privée

## Objectif

Mettre en place un mini pipeline CI/CD local automatisant :
- La construction d'une image Docker personnalisée pour l'application Flask
- Le tag et l'envoi vers une registry Docker privée (`registry:2`)
- Le redéploiement automatique via `docker compose`

## Architecture du pipeline

```
┌─────────────────┐
│  Code Source    │
│   (app.py)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ docker build    │
│ (Dockerfile)    │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────┐
│ Image Docker (localhost:5000)   │
│       app:latest                │
└────────┬────────────────────────┘
         │
         ▼
┌──────────────────────────┐
│  docker push             │
│  (Registry:5000)         │
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│ docker compose down      │
│ docker compose up -d     │
└──────────────────────────┘
         │
         ▼
    ✅ Nouveau déploiement
```

## Registry Docker privée

### Service défini dans `compose.yml`

```yaml
  registry:
    image: registry:2
    ports:
      - "5000:5000"
    networks:
      - secure_back
    restart: unless-stopped
    volumes:
      - registry-data:/var/lib/registry
```

### Caractéristiques

- **Image** : `registry:2` (registry Docker officielle)
- **Port** : 5000 (accessible en local sur `localhost:5000`)
- **Network** : `secure_back` (réseau interne, non exposé directement)
- **Persistance** : Volume nommé `registry-data` pour stocker les images

### Adresse complète de la registry

```
localhost:5000
```

Les images sont stockées sur la VM et sont accessibles uniquement en local depuis Docker.

## Image de l'application Flask

### Dockerfile (`app/Dockerfile`)

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY app.py /app/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    apt-get update && apt-get install -y iptables && \
    pip install flask pymysql && \
    rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python", "app.py"]
```

### Explication ligne par ligne

- `FROM python:3.11-slim` : Image de base très légère (Debian + Python 3.11)
- `WORKDIR /app` : Définit le répertoire de travail
- `COPY app.py /app/` : Copie le code source Flask
- `COPY entrypoint.sh /entrypoint.sh` : Copie le script d'initialisation
- `RUN chmod +x /entrypoint.sh` : Rend le script exécutable
- `apt-get update && apt-get install -y iptables` : Installe iptables (pour bloquer le ping)
- `pip install flask pymysql` : Installe les dépendances Python
- `rm -rf /var/lib/apt/lists/*` : Réduit la taille de l'image
- `ENTRYPOINT ["/entrypoint.sh"]` : Exécute le script au démarrage du conteneur
- `CMD ["python", "app.py"]` : Lance l'application Flask

### Configuration Docker Compose

Dans le service `app` :

```yaml
  app:
    image: localhost:5000/app:latest
    environment:
      DB_HOST: db
      DB_USER: appuser
      DB_PASS: apppass
      DB_NAME: appdb
    networks:
      - secure_back
      - secure_front
```

L'application est lancée avec les credentials MariaDB et est connectée à deux réseaux.

## Pipeline manuel : Commandes étape par étape

### Étape 1 : Build l'image

```bash
docker build -t localhost:5000/app:latest ./app
```

- `docker build` : Construit une image à partir d'un Dockerfile
- `-t localhost:5000/app:latest` : Tag l'image avec le nom `localhost:5000/app` et la version `latest`
- `./app` : Chemin vers le répertoire contenant le Dockerfile

**Output attendu** :
```
Successfully tagged localhost:5000/app:latest
```

### Étape 2 : Push vers la registry privée

```bash
docker push localhost:5000/app:latest
```

- Envoie l'image vers la registry locale sur le port 5000
- Nécessite que le service `registry` soit démarré

**Output attendu** :
```
The push refers to repository [localhost:5000/app]
latest: digest: sha256:xxxxxxxxxxxxx size: xxxx
```

### Étape 3 : Arrêter les anciens conteneurs

```bash
docker compose down
```

- Arrête et supprime tous les conteneurs du projet
- **Ne supprime pas** les volumes (les données persistent)

### Étape 4 : Redémarrer les services

```bash
docker compose up -d
```

- Crée et démarre les conteneurs
- `-d` : Mode détaché (s'exécute en arrière-plan)
- Le service `app` télécharge la nouvelle image depuis la registry et redémarre

## Script automatisé : build.sh

Pour éviter de refaire ces étapes manuellement, un script `build.sh` automatise le pipeline :

```bash
#!/bin/bash
set -e

IMAGE_NAME=localhost:5000/app:latest

echo "[*] Building image..."
docker build -t $IMAGE_NAME ./app

echo "[*] Pushing to registry..."
docker push $IMAGE_NAME

echo "[*] Stopping containers..."
docker compose down

echo "[*] Starting services..."
docker compose up -d

echo "[+] Pipeline completed successfully"
```

### Explication du script

- `set -e` : Arrête l'exécution si une commande échoue
- `IMAGE_NAME=...` : Variable pour ne pas répéter l'URL
- `echo` : Affiche un message de statut
- Exécute les 4 étapes décrites plus haut

### Utilisation

```bash
chmod +x build.sh
./build.sh
```

Le script affichera :
```
[*] Building image...
...
[*] Pushing to registry...
...
[*] Stopping containers...
...
[*] Starting services...
...
[+] Pipeline completed successfully
```

## Flux de déploiement complet

### Scénario : Mise à jour du code

1. **Modifier le code** dans `app/app.py`

2. **Exécuter le pipeline** :
   ```bash
   ./build.sh
   ```

3. **Détails techniques** :
   - Docker lit le Dockerfile
   - Crée une nouvelle image avec le code mis à jour
   - Tag cette image `localhost:5000/app:latest`
   - Envoie l'image vers la registry (stockée sur disk)
   - Arrête les vieux conteneurs
   - Redémarre `docker compose`
   - Docker Compose récupère la nouvelle image `localhost:5000/app:latest`
   - Lance le nouveau conteneur `app` avec le code mis à jour

4. **Vérification** :
   ```bash
   docker compose ps
   # Le conteneur 'app' devrait être 'Up' et récent
   ```

## Commandes utiles pour le CI/CD

### Vérifier les images locales

```bash
docker images | grep app
```

### Voir les images stockées dans la registry

```bash
curl -s http://localhost:5000/v2/_catalog | jq
```

Affiche :
```json
{
  "repositories": [
    "app"
  ]
}
```

### Voir les tags d'une image dans la registry

```bash
curl -s http://localhost:5000/v2/app/tags/list | jq
```

Affiche :
```json
{
  "name": "app",
  "tags": [
    "latest"
  ]
}
```

### Vérifier le pull depuis la registry

```bash
docker pull localhost:5000/app:latest
```

### Voir les logs du build

```bash
docker compose logs app -f
```

## Problèmes courants et solutions

### Erreur : "Cannot connect to registry"

```
error pulling image configuration: Get "http://localhost:5000/v2/app/manifests/sha256:...": 
EOF
```

**Cause** : La registry n'est pas démarrée

**Solution** :
```bash
docker compose up -d registry
```

### Erreur : "Failed to push image"

```
error pushing to registry: errors:
denied: requested access to the resource is denied
```

**Cause** : Problème de permission ou registry invalide

**Solution** :
```bash
# Vérifier que la registry est accessible
curl http://localhost:5000/v2/

# Redémarrer la registry
docker compose restart registry
```

### Image trop volumineux

**Cause** : Beaucoup de couches inutiles dans le Dockerfile

**Solution** : Utiliser `slim` ou `alpine` comme image de base, nettoyer les cache APT

## Avantages du pipeline local

1. **Rapidité** : Build et push en quelques secondes
2. **Isolation** : Les images restent en local
3. **Contrôle** : Full control sur chaque étape
4. **Reproductibilité** : Même code = même image

## Différence avec un CI/CD production

| Aspect | Local | Production |
|--------|-------|-----------|
| Registry | Locale (port 5000) | Distante (Docker Hub, GitLab, etc.) |
| Déploiement | Manual (`./build.sh`) | Automatic (webhook, trigger) |
| Version | `latest` | Semver (`v1.0.0`, etc.) |
| Environnement | Dev/Test | Staging/Prod |
| Security | Trust-local | Registry auth |
