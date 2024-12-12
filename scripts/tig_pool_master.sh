#!/bin/bash

# Fonction pour afficher l'usage
usage() {
    echo "Usage: $0 -id_slave <id_slave> -nom_slave <nom_slave> -ip <ip> -v <version> -login <login_discord> -tok <private_key> -url <URL_SERVER>"
    exit 1
}

# Vérifier que le nombre total d'arguments est bien 14 (7 options + 7 valeurs)
if [ "$#" -ne 14 ]; then
    usage
fi

# Initialiser les variables pour les paramètres
id_slave=""
nom_slave=""
ip=""
v=""
login_discord=""
private_key=""
URL_SERVER=""

# Récupérer les arguments en entrée
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -id_slave)
            id_slave="$2"
            shift 2
            ;;
        -nom_slave)
            nom_slave="$2"
            shift 2
            ;;
        -ip)
            ip="$2"
            shift 2
            ;;
        -v)
            v="$2"
            shift 2
            ;;
        -login)
            login_discord="$2"
            shift 2
            ;;
        -tok)
            private_key="$2"
            shift 2
            ;;
        -url)
            URL_SERVER="$2"
            shift 2
            ;;
        *)
            echo "Paramètre inconnu : $1"
            usage
            ;;
    esac
done

# Vérifier que les variables ne sont pas vides
if [ -z "$id_slave" ] || [ -z "$nom_slave" ] || [ -z "$ip" ] || [ -z "$v" ] || [ -z "$login_discord" ] || [ -z "$private_key" ] || [ -z "$URL_SERVER" ]; then
    usage
fi

# Vérifier que screen est installé
if ! command -v screen &> /dev/null; then
    echo "Le programme 'screen' est nécessaire mais n'est pas installé. Installation..."
    sudo apt install -y screen
fi

# Afficher les paramètres (ou exécuter une autre logique avec ces valeurs)
echo "ID Slave: $id_slave"
echo "Nom Slave: $nom_slave"
echo "IP: $ip"
echo "VERSION: $v"
echo "Login Discord: $login_discord"
echo "Private Key: $private_key"
echo "URL Server: $URL_SERVER"

sudo apt update
sudo apt install -y python3 python3-venv python3-dev
sudo apt install -y build-essential
sudo apt install -y cargo
sudo apt install -y curl tmux git libssl-dev pkg-config
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
sudo apt install -y libssl-dev

# Créer le répertoire tig_pool_test et y naviguer
mkdir -p "tig_pool_xnico_v$v"
cd "tig_pool_xnico_v$v"
mkdir -p wasms
sudo chmod -R 777 wasms/
# Cloner le dépôt git avec la branche spécifiée
git clone https://github.com/tig-pool-nk/tig-monorepo.git

#curl -o "tig-monorepo/tig-benchmarker/slave.py" "http://tigpool.xyz/echange/slave.py"

# Créer un environnement virtuel Python et l'activer
python3 -m venv mon_env
source mon_env/bin/activate

# Naviguer vers le répertoire du benchmarker et construire le projet avec cargo
cd tig-monorepo/tig-benchmarker/
cargo build -p tig-worker --release

 

# Installer les dépendances Python
pip install -r requirements.txt
pip install requests

# Récupérer le chemin relatif actuel et le stocker dans une variable
current_path=$(pwd)
echo "Le chemin relatif est : $current_path"

# Retourner au répertoire précédent
cd ../..
current_path=$(pwd)
echo "Le chemin relatif est : $current_path"

# Créer un répertoire client_xnico_pool_v1 et y naviguer
mkdir -p client_xnico_pool
cd client_xnico_pool

# Télécharger les fichiers et vérifier le succès du téléchargement
wget http://$ip/out/clients/v$v/client_v$v -O client_tig_pool_v$v
if [ $? -ne 0 ]; then
    echo "Erreur lors du téléchargement de client_tig_pool_v$v"
    exit 1
fi

wget http://$ip/out/clients/v$v/bench_v$v -O bench_v$v
if [ $? -ne 0 ]; then
    echo "Erreur lors du téléchargement de bench"
    exit 1
fi

# Donner les permissions d'exécution aux deux fichiers
chmod +x client_tig_pool_v$v
chmod +x bench_v$v

# Revenir dans le répertoire parent
cd ..

# Télécharger le fichier de lancement et le renommer en fonction des paramètres fournis
wget -O pool_tig_launch_${id_slave}_${nom_slave}.sh http://$ip/out/master/pool_tig_launch_master.sh

# Remplacer les placeholders par les valeurs des variables
sed -i "s|@id@|$id_slave|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@login@|$login_discord|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@tok@|$private_key|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@worker@|$nom_slave|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@ip@|$ip|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@url@|http://$URL_SERVER|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@v@|$v|g" pool_tig_launch_${id_slave}_${nom_slave}.sh

# Donner les permissions d'exécution au fichier de lancement
chmod +x pool_tig_launch_${id_slave}_${nom_slave}.sh

# Remplacer @@path@@ par le chemin actuel dans le fichier de lancement
sed -i "s|@@path@@|$current_path/|g" pool_tig_launch_${id_slave}_${nom_slave}.sh

echo "Script terminé avec succès. Les fichiers ont été téléchargés, configurés et le chemin a été mis à jour."

# Lancer un nouveau screen appelé pool_tig et exécuter le script pool_tig_launch_${id_slave}_${nom_slave}.sh
screen -dmS pool_tig bash -c "cd \"$current_path\" && ./pool_tig_launch_${id_slave}_${nom_slave}.sh ; exec bash"

sleep 5
# Aller dans le screen
screen -r pool_tig
