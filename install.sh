#!/bin/bash

# Vérification du nombre d'arguments
if [ "$#" -ne 7 ] && [ "$#" -ne 8 ]; then
    echo "wrong parameters"
    exit 1
fi

# Affectation des paramètres
slave_id=$1
slave_name=$2
server_url=$3
port=$4
login=$5
private_key=$6
client_version=$7

# Définir la branche par défaut sur "main"
branch="main"

# Vérifier si un 8ème argument est passé et correspond à "testnet"
if [ "$#" -eq 8 ] && [ "$8" = "testnet" ]; then
    branch="test"
fi

if [ -z "$branch" ]; then
    echo "Error: Branch not defined."
    exit 1
fi

# Affichage des paramètres pour debug
echo "Slave ID: $slave_id"
echo "Slave Name: $slave_name"
echo "Server URL: $server_url"
echo "Port: $port"
echo "Login: $login"
echo "Private Key: $private_key"
echo "Client Version: $client_version"
echo "Branch: $branch"

# Suppression et recréation du répertoire
rm -rf "tig_pool_$branch"
mkdir "tig_pool_$branch"
cd "tig_pool_$branch" || exit 1

# Arrêter les écrans nommés pool_tig existants
screen -ls | grep pool_tig | awk '{print $1}' | xargs -I {} screen -S {} -X kill

# Télécharger et exécuter le script mis à jour
script_url="https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/tig_pool_master.sh"
echo "Downloading script from: $script_url"

wget "$script_url"
if [ $? -ne 0 ]; then
    echo "Error downloading script. Please check the branch and URL."
    exit 1
fi

sudo chmod +x tig_pool_master.sh

# Exécuter le script téléchargé avec les paramètres appropriés
./tig_pool_master.sh \
    -id_slave "$slave_id" \
    -nom_slave "$slave_name" \
    -ip "$server_url" \
    -port "$port" \
    -login "$login" \
    -tok "$private_key" \
    -url "$server_url" \
    -v "$client_version" \
    -b "$branch"
