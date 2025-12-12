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

# Accepter les connexions depuis le réseau backend_net (172.30.0.0/24) SAUF la gateway
iptables -A INPUT -s 172.30.0.0/24 -j ACCEPT

# Accepter les connexions depuis le réseau frontend_net (172.30.1.0/24) SAUF la gateway
iptables -A INPUT -s 172.30.1.0/24 -j ACCEPT

# Accepter les connexions établies et reliées
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

