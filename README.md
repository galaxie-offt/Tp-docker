# Projet Docker : Isolation réseau backend_net

Ce projet met en place une infrastructure Docker avec trois services :
- db : base de données MariaDB
- app : application Flask qui interroge la base
- proxy : serveur Nginx en reverse proxy

## Objectif

Empêcher la VM d'accéder directement au réseau Docker `backend_net` contenant la base de données, tout en permettant l'accès via le proxy Nginx.

## Configuration Docker-Compose

```yaml
version: '3.9'

networks:
  backend_net:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.30.0.0/24
  frontend_net:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.30.1.0/24

services:
  db:
    image: mariadb:latest
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: appdb
      MYSQL_USER: appuser
      MYSQL_PASSWORD: apppass
    networks:
      - backend_net
    restart: unless-stopped

  app:
    build: ./app
    environment:
      DB_HOST: db
      DB_USER: appuser
      DB_PASS: apppass
      DB_NAME: appdb
    networks:
      - backend_net
    restart: unless-stopped

  proxy:
    image: nginx:latest
    volumes:
      - ./proxy/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - "80:80"
    networks:
      - frontend_net
      - backend_net
    restart: unless-stopped
```

## Dockerfile app

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY app.py /app/

RUN pip install flask pymysql

CMD ["python", "app.py"]
```

## Architecture réseau

- **backend_net (172.30.0.0/24)** : réseau interne pour la base de données et l'application
  - db : 172.30.0.2 (exemple)
  - app : 172.30.0.3 (exemple)

- **frontend_net (172.30.1.0/24)** : réseau pour le proxy exposé à l'extérieur
  - proxy : 172.30.1.2 (exemple)

- **proxy** : en tant qu'intermédiaire connecté aux deux réseaux

## Phases de test pour vérifier le fonctionnement

### Phase 1 : Démarrage des services

1. Lancez les conteneurs :
```bash
docker-compose up -d
```

2. Vérifiez que tous les conteneurs sont en cours d'exécution :
```bash
docker-compose ps
```

Vous devez voir les trois services en état `running`.

### Phase 2 : Vérification de la connectivité interne

1. Testez la connexion de l'app vers la base de données :
```bash
docker-compose exec app curl http://localhost:5000/health
```

Vous devez obtenir une réponse JSON avec `"status":"ok"` et `"db":"reachable"`.

2. Testez la page d'accueil de l'app :
```bash
docker-compose exec app curl http://localhost:5000/
```

Vous devez voir la réponse "Hello from app!"

### Phase 3 : Accès via le proxy depuis la VM

1. Depuis la VM, ouvrez un navigateur et allez à :
```
http://localhost/
```

Vous devez voir "Hello from app!" s'afficher.

2. Testez le endpoint health :
```bash
curl http://localhost/health
```

Vous devez obtenir :
```json
{"status":"ok","db":"reachable"}
```

### Phase 4 : Vérification de l'isolation réseau

1. Identifiez l'interface bridge Docker sur la VM :
```bash
ip a | grep 172.30.0
```

Vous verrez une interface comme `br-89f753f7bad2` avec l'IP `172.30.0.1`.

2. Testez l'accès direct depuis la VM vers la base de données (avant isolation) :
```bash
mysql -h 172.30.0.2 -u appuser -p apppass -D appdb -e "SELECT 1"
```

Si la connexion réussit, cela signifie que la VM accède directement à backend_net.

### Phase 5 : Mise en place de l'isolation (blocage firewall)

1. Bloquez tout trafic sortant de la VM vers le réseau backend_net :
```bash
sudo iptables -A OUTPUT -d 172.30.0.0/24 -j DROP
```

2. Vérifiez que le blocage fonctionne en essayant de se connecter à la base :
```bash
mysql -h 172.30.0.2 -u appuser -p apppass -D appdb -e "SELECT 1"
```

Cette tentative doit échouer avec un timeout (connection refused).

3. Testez que l'accès via le proxy fonctionne toujours :
```bash
curl http://localhost/health
```

Vous devez toujours obtenir une réponse positive car le proxy n'est pas bloqué.

### Phase 6 : Tests avancés

1. Vérifiez que les conteneurs peuvent toujours communiquer entre eux :
```bash
docker network inspect tp-networks_backend_net
```

Vous devez voir les conteneurs db et app connectés à ce réseau.

2. Testez la résolution DNS interne (depuis l'app) :
```bash
docker-compose exec app ping db
```

Le ping doit fonctionner (la base est joignable par son nom).

3. Confirmez que la base n'est pas accessible directement depuis l'extérieur :
```bash
telnet <IP_VM> 3306
```

Cela ne doit pas fonctionner (aucun port exposé).

## Commandes utiles

### Vérifier les logs des conteneurs
```bash
docker-compose logs db
docker-compose logs app
docker-compose logs proxy
```

### Afficher les configurations réseau
```bash
docker network ls
docker network inspect tp-networks_backend_net
docker network inspect tp-networks_frontend_net
```

### Accéder à un conteneur en shell
```bash
docker-compose exec app bash
docker-compose exec db bash
docker-compose exec proxy bash
```

### Arrêter et nettoyer
```bash
docker-compose down
docker network prune -f
```

### Vérifier les règles iptables actives
```bash
sudo iptables -L -n
```

### Revenir en arrière (supprimer la règle de blocage)
```bash
sudo iptables -D OUTPUT -d 172.30.0.0/24 -j DROP
```

## Résumé de l'isolation

| Accès | Depuis | Vers | Résultat |
| --- | --- | --- | --- |
| VM -> backend_net | 10.5.x.x | 172.30.0.0/24 | BLOQUÉ (firewall) |
| VM -> proxy (http) | 10.5.x.x | port 80 (proxy) | AUTORISÉ |
| proxy -> app | frontend_net | backend_net | AUTORISÉ |
| proxy -> db | frontend_net | backend_net | AUTORISÉ |
| app -> db | backend_net | backend_net | AUTORISÉ |
| VM -> db (direct) | 10.5.x.x | 3306 (db) | BLOQUÉ (pas de port exposé) |

## Conclusion

L'isolation du réseau backend_net est garantie par :
1. La création de deux réseaux Docker distincts
2. Le proxy en tant que seul intermédiaire entre frontend et backend
3. Aucun port exposé pour la base de données
4. Une règle firewall bloquant la VM vers le réseau backend_net

Seul le proxy peut communiquer avec l'application et la base, tandis que la VM n'accède à l'application que via le proxy sur le port 80.
