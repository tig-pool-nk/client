#!/bin/bash

if [ "$#" -ne 7 ]; then
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

\rm -rf tig_pool
\mkdir tig_pool
cd tig_pool

screen -ls | grep pool_tig | awk '{print $1}' | xargs -I {} screen -S {} -X kill

wget https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/scripts/tig_pool_master.sh
sudo chmod +x tig_pool_master.sh
./tig_pool_master.sh -id_slave $slave_id -nom_slave $slave_name -ip $server_url -port $port -login $login -tok $private_key -url $server_url -v $client_version
