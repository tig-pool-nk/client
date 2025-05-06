#!/bin/bash

# Vérification du nombre d'arguments
if [ "$#" -ne 5 ] && [ "$#" -ne 6 ]; then
    echo "wrong parameters"
    exit 1
fi

# Affectation des paramètres
slave_id=$1
server_url=$2
login=$3
private_key=$4
client_version=$5

install_url="${BASH_SOURCE[0]}"
if [[ "$install_url" == "/dev/fd/"* ]]; then
  install_url=$(cat /proc/$$/cmdline | tr '\0' '\n' | grep -Eo 'https://[^ ]+')
fi

# Définir la branche par défaut sur "main"
branch="main"

# Vérifier si un 8ème argument est passé et correspond à "testnet"
if [ "$#" -eq 6 ] && [ "$6" = "testnet" ]; then
    branch="test"
fi

if [ -z "$branch" ]; then
    echo "Error: Branch not defined."
    exit 1
fi

# Affichage des paramètres pour debug
echo "Slave ID: $slave_id"
echo "Server URL: $server_url"
echo "Login: $login"
echo "Private Key: $private_key"
echo "Client Version: $client_version"
echo "Branch: $branch"

# Suppression et recréation du répertoire
rm -rf "tig_pool_$branch"
mkdir "tig_pool_$branch"
cd "tig_pool_$branch" || exit 1

# Save parameters
cat > ".tig_env" <<EOF
PATH=$PWD/tig_pool_$branch
ID_SLAVE=$ID_SLAVE
MASTER=$MASTER
LOGIN_DISCORD=$LOGIN_DISCORD
TOKEN=$TOKEN
MODE=$MODE
INSTALL_URL=$INSTALL_URL
EOF

# Save version
CONFIG_FILE=".tig_env"
cat > "version.txt" <<EOF
$VERSION
EOF

# Arrêter les écrans nommés pool_tig existants
screen -ls | grep pool_tig | awk '{print $1}' | xargs -I {} screen -S {} -X kill

# Télécharger et exécuter le script mis à jour
script_url="https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/tig_pool_master.sh"
echo "Downloading script from: $script_url"

wget --no-cache "$script_url"
if [ $? -ne 0 ]; then
    echo "Error downloading script. Please check the branch and URL."
    exit 1
fi

sudo chmod +x tig_pool_master.sh

# Exécuter le script téléchargé avec les paramètres appropriés
./tig_pool_master.sh \
    -id_slave "$slave_id" \
    -ip "$server_url" \
    -login "$login" \
    -tok "$private_key" \
    -url "$server_url" \
    -v "$client_version" \
    -b "$branch"
