#!/bin/bash

if [ "$#" -ne 7 ] && [ "$#" -ne 8 ]; then
    echo "wrong parameters"
    exit 1
fi

slave_id=$1
slave_name=$2
server_url=$3
port=$4
login=$5
private_key=$6
client_version=$7

if [ "$#" -eq 8 ] && [ "$8" = "testnet" ]; then
    branch="test"
fi

# Remove existing directory and recreate
rm -rf "tig_pool_$branch"
mkdir "tig_pool_$branch"
cd "tig_pool_$branch" || exit 1

# Kill any existing screens named pool_tig
screen -ls | grep pool_tig | awk '{print $1}' | xargs -I {} screen -S {} -X kill

# Download and run the updated script
wget "https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/tig_pool_master.sh"
sudo chmod +x tig_pool_master.sh

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
