#!/bin/bash
#!/bin/bash

# Variables globales
id_slave="@id@"
login_discord="@login@"
token_private="@tok@"
nom_machine="@worker@"

# Serveur TIG
ip="@ip@"
port="6666"
add_tig=""

# WEB + port 
url="@url@"


# Chemin du TIG, chemin absolu
path_tig='@@path@@'

# Nom du fichier client
client_file="/client_xnico_pool/client_tig_pool_v@v@"
# Nom du fichier client


# Chemins relatifs à vérifier
path_env="$path_tig/mon_env"
worker_path="$path_tig/tig-monorepo/target/release/tig-worker"


# Vérifier si l'environnement virtuel Python existe
if [ ! -d "$path_env" ]; then
    echo "L'environnement virtuel mon_env n'existe pas. Veuillez le créer avant de continuer."
    echo "Pour le créer, exécutez :"
    echo "python3 -m venv $path_env"
    exit 1
fi

# Vérifier si le worker est présent
if [ ! -f "$worker_path" ]; then
    echo "Le fichier tig-worker n'existe pas à l'emplacement $worker_path. Veuillez le build avant de continuer."
    echo "Pour le build, exécutez :"
    echo "cd $path_tig/tig-monorepo && cargo build --release"
    exit 1
fi



# Si les vérifications sont passées, exécuter le client Python
./"$client_file" --path_to_tig "$path_tig" --id_slave "$id_slave" --login_discord "$login_discord" --token_private "$token_private" --ip "$ip"  --port "$port" --add_tig "$add_tig" --url "$url"




