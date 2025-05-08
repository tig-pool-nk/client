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
mkdir -p $HOME/.tig/$branch
rm -rf "tig_pool_$branch"
mkdir "tig_pool_$branch"
cd "tig_pool_$branch" || exit 1

# Save parameters
install_url="https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/install.sh"
cat > "$HOME/.tig/$branch/.tig_env" <<EOF
TIG_PATH=$PWD
ID_SLAVE=$slave_id
MASTER=$server_url
LOGIN_DISCORD=$login
TOKEN=$private_key
BRANCH=$branch
MODE=$6
INSTALL_URL=$install_url
EOF

# Save version
cat > "$HOME/.tig/$branch/version.txt" <<EOF
$client_version
EOF

# Kill old processes
MAX_ATTEMPTS=20
PORTS=(50800 50801)
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
    echo "Attempt $attempt to clean up processes..."

    ps aux | grep -i pool_tig_launch | awk '{print $2}' | xargs kill -9 2>/dev/null || true
    ps aux | grep -i tig_update_watcher | awk '{print $2}' | xargs kill -9 2>/dev/null || true
    
    if [[ -d "bin" ]]; then
        for p in $(ls bin); do
            killall "$p" > /dev/null 2>&1 || true
        done
    fi
    
    for port in "${PORTS[@]}"; do
        fuser -k "${port}/tcp" 2>/dev/null || true
    done

    screen -ls | grep pool_tig | awk '{print $1}' | xargs -I {} screen -S {} -X kill 2>/dev/null || true
    screen -ls | grep tig_updater | awk '{print $1}' | xargs -I {} screen -S {} -X kill 2>/dev/null || true
    screen -wipe > /dev/null 2>&1 || true

    TIME_WAIT_TIMEOUT=10
    while ss -tnap | grep -E "50800|50801" | grep TIME-WAIT > /dev/null; do
        echo "TIG miner is still running: waiting for sockets to close, please be patient..."
        sleep 1
        ((TIME_WAIT_TIMEOUT--))
        if [[ "$TIME_WAIT_TIMEOUT" -le 0 ]]; then
            echo "Timeout reached, retrying cleanup..."
            break
        fi
    done

    if ! lsof -i tcp:50800 -t > /dev/null 2>&1 && \
        ! lsof -i tcp:50801 -t > /dev/null 2>&1 && \
        ! ss -tnap | grep -E "50800|50801" | grep -q TIME-WAIT; then
        echo "Processes successfully cleaned up."
        break
    fi

    if [[ "$attempt" -eq "$MAX_ATTEMPTS" ]]; then
        echo "ERROR: TIG miner is still running after $MAX_ATTEMPTS attempts (ports 50800 or 50801 are still in use)."
        return
    fi

    sleep 1
done

# Télécharger et exécuter le script mis à jour
script_url="https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/tig_pool_master.sh"
echo "Downloading script from: $script_url"

wget --no-cache "$script_url"
if [ $? -ne 0 ]; then
    echo "Error downloading script. Please check the branch and URL."
    exit 1
fi

chmod +x tig_pool_master.sh

# Exécuter le script téléchargé avec les paramètres appropriés
./tig_pool_master.sh \
    -id_slave "$slave_id" \
    -ip "$server_url" \
    -login "$login" \
    -tok "$private_key" \
    -url "$server_url" \
    -v "$client_version" \
    -b "$branch"
