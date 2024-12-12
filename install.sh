#!/bin/bash

if [ "$#" -ne 6 ]; then
    exit 1
fi

slave_id=$1
slave_name=$2
server_url=$3
login=$4
private_key=$5
client_version=$6

\rm -rf tig_pool
\mkdir tig_pool
cd tig_pool

pkill pool_tig
pkill slave_tig

wget https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/scripts/tig_pool_master.sh
sudo chmod +x tig_pool_master.sh
./tig_pool_master.sh -id_slave " . $slave_id . " -nom_slave " . $slave_name ." -ip ".$server_url . " -login " .$login . " -tok " .$private_key . " -url " .$server_url . " -v " .$client_version