#!/bin/bash
set -e

# Bloque le ping ICMP dans le conteneur app
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP

# Exécute la commande par défaut
exec "$@"
