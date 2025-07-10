
#!/bin/bash
set -euo pipefail

# Fonction pour vérifier l'espace disque disponible
check_disk_space() {
    echo "🔹 Checking available disk space..."
    
    # Obtenir l'espace disponible en MB
    available_space_mb=$(df . | tail -1 | awk '{print $4}')
    
    # Convertir en GB (approximatif)
    available_space_gb=$((available_space_mb / 1024))
    
    echo "Available disk space: ${available_space_gb} GB"
    
    # Vérifier si moins de 1 GB disponible
    if [ "$available_space_gb" -lt 1 ]; then
        echo "⚠️  WARNING: Not enough disk space available!"
        echo "❌ ERROR: Only ${available_space_gb} GB available. Minimum required: 1 GB"
        echo "Please free up disk space before running the installation."
        exit 1
    fi
    
    if [ "$available_space_gb" -lt 2 ]; then
        echo "⚠️  WARNING: Low disk space detected (${available_space_gb} GB available)"
        echo "💡 Recommended: At least 2 GB for optimal performance"
    fi
    
    echo "✅ Disk space check passed"
}

# Affectation des paramètres
slave_id=$1
server_url=$2
login=$3
private_key=$4
client_version=$5

# Définir la branche par défaut sur "main"
MODE="mainnet"
branch="main"

SKIP_SYSTEM_SETUP="false"
HIVE_MODE="false"

# Détection automatique de HiveOS
detect_hiveos() {
    # Vérifier si on est sur HiveOS en cherchant le fichier de configuration spécifique
    if [[ -f "/hive-config/rig.conf" ]]; then
        return 0  # HiveOS détecté
    fi
    return 1  # Pas HiveOS
}

# Détection automatique de HiveOS
if detect_hiveos; then
    HIVE_MODE="true"
    echo "HiveOS automatically detected!"
fi

# Vérification de l'espace disque disponible
check_disk_space

for arg in "$@"; do
    if [[ "$arg" == "--no-system-setup" ]]; then
        SKIP_SYSTEM_SETUP="true"
    elif [[ "$arg" == "hive" ]]; then
        HIVE_MODE="true"
    fi
done

# Si mode hive, vérifier qu'on est en tant qu'utilisateur user et dans /home/user
if [[ "$HIVE_MODE" == "true" ]]; then
    if [[ "$EUID" -eq 0 ]]; then
        echo "ERROR: For HiveOS mode, please run this script as user 'user', not as root."
        echo "Please run: su user"
        echo "Then go to: cd /home/user"
        echo "Then run the script again."
        exit 1
    fi
    
    if [[ "$PWD" != "/home/user" ]]; then
        echo "ERROR: For HiveOS mode, please run this script from /home/user directory."
        echo "Please run: cd /home/user"
        echo "Then run the script again."
        exit 1
    fi
    
    echo "HiveOS mode detected - running as user in /home/user"
fi

# Vérifier si un 8ème argument est passé et correspond à "testnet"
if [ -n "${6:-}" ] && [ "$6" = "testnet" ]; then
    branch="test"
    MODE="testnet"
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
echo "Hive Mode: $HIVE_MODE"

# Suppression et recréation du répertoire
mkdir -p $HOME/.tig/$branch
if [[ "$HIVE_MODE" == "true" ]]; then
    sudo rm -rf "tig_pool_$branch"
else
    rm -rf "tig_pool_$branch"
fi
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
MODE=$MODE
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

    pgrep -f pool_tig_launch | xargs kill -9 2>/dev/null || true
    pgrep -f tig_update_watcher | xargs kill -9 2>/dev/null || true
    
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
        exit 1
    fi

    sleep 1
done

# Télécharger et exécuter le script mis à jour
script_url="https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/tig_pool_master.sh"
echo "Downloading script from: $script_url"
if ! command -v wget > /dev/null; then
    echo "wget is not installed. Please install it first."
    exit 1
fi

wget --no-cache "$script_url"
if [ $? -ne 0 ]; then
    echo "Error downloading script. Please check the branch and URL."
    exit 1
fi

chmod +x tig_pool_master.sh

# Exécuter le script téléchargé avec les paramètres appropriés
if [[ "$HIVE_MODE" == "true" ]]; then
    ./tig_pool_master.sh \
        -id_slave "$slave_id" \
        -ip "$server_url" \
        -login "$login" \
        -tok "$private_key" \
        -url "$server_url" \
        -v "$client_version" \
        -b "$branch" \
        -no_setup "$SKIP_SYSTEM_SETUP" \
        -hive "true"
else
    ./tig_pool_master.sh \
        -id_slave "$slave_id" \
        -ip "$server_url" \
        -login "$login" \
        -tok "$private_key" \
        -url "$server_url" \
        -v "$client_version" \
        -b "$branch" \
        -no_setup "$SKIP_SYSTEM_SETUP"
fi