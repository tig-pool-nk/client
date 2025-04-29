#!/bin/bash
current_dir=$(basename "$PWD")
if [ "$current_dir" != "tig_pool_main" ]; then
    echo "Error: You are not in the 'tig_pool_main' directory."
    echo "Please navigate to the 'tig_pool_main' directory."
    exit 1
fi

launch_file=$(ls pool_tig_launch* 2>/dev/null | head -n 1)
if [ -z "$launch_file" ]; then
    echo "Error: No file matching 'pool_tig_launch*' found."
    exit 1
fi

echo "File found: $launch_file"

id_slave=$(grep '^id_slave=' "$launch_file" | sed 's/.*="\([^"]*\)".*/\1/')
login_discord=$(grep '^login_discord=' "$launch_file" | sed 's/.*="\([^"]*\)".*/\1/')
token_private=$(grep '^token_private=' "$launch_file" | sed 's/.*="\([^"]*\)".*/\1/')

if [ -z "$id_slave" ] || [ -z "$login_discord" ] || [ -z "$token_private" ]; then
    echo "Error: One or more variables are not defined in the file."
    exit 1
fi

echo "Variables extracted:"
echo "id_slave = $id_slave"
echo "login_discord = $login_discord"
echo "token_private = $token_private"

cd ~

echo "Note: This script will kill all running screens. Do you wish to continue? [y/n]"
read answer
if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
    echo "Aborting operation."
    exit 1
fi

sudo pkill screen
sudo pkill client_tig_pool
sudo pkill slave
sudo pkill bench

bash <(wget --no-cache -qO- https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/install.sh) $id_slave bench.tigpool.com $login_discord $token_private 22 mainnet
