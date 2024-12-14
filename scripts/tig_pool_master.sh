#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 -id_slave <id_slave> -nom_slave <nom_slave> -ip <ip> -port <port> -login <login_discord> -tok <private_key> -url <URL_SERVER>"
    exit 1
}

# Check if the total number of arguments ok
if [ "$#" -ne 16 ]; then
    usage
fi

# Initialize variables for parameters
id_slave=""
nom_slave=""
ip=""
port=""
v=""
login_discord=""
private_key=""
URL_SERVER=""

# Parse input arguments
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
        -port)
            port="$2"
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
            echo "Unknown parameter: $1"
            usage
            ;;
    esac
done

# Ensure variables are not empty
if [ -z "$id_slave" ] || [ -z "$nom_slave" ] || [ -z "$ip" ] || [ -z "$port" ] || [ -z "$login_discord" ] || [ -z "$private_key" ] || [ -z "$URL_SERVER" ]; then
    usage
fi

# Check if 'screen' is installed
if ! command -v screen &> /dev/null; then
    echo "The 'screen' program is required but not installed. Installing..."
    sudo apt install -y screen
fi

current_path=$(pwd)

# Display parameters (or execute other logic with these values)
echo "ID Slave: $id_slave"
echo "Slave Name: $nom_slave"
echo "IP: $ip"
echo "Port: $port"
echo "Login: $login_discord"
echo "Private Key: $private_key"
echo "URL Server: $URL_SERVER"
echo "Current path: $current_path"

sudo apt update
sudo apt install -y python3 python3-venv python3-dev
sudo apt install -y build-essential
sudo apt install -y cargo
sudo apt install -y curl tmux git libssl-dev pkg-config
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
sudo apt install -y libssl-dev

# Create the directory tig_pool_test and navigate to it
mkdir -p wasms
sudo chmod -R 777 wasms/
# Clone the Git repository with the specified branch
git clone https://github.com/tig-foundation/tig-monorepo.git

# Navigate to the benchmarker directory and build the project with cargo
cd tig-monorepo/tig-worker/
cargo build -p tig-worker --release

# Install the benchmarker
cd $current_path

python3 -m venv venv

mkdir -p tig-benchmarker
cd tig-benchmarker
wget https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/tig-benchmarker/slave.py -O slave.py
wget https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/tig-benchmarker/requirements.txt -O requirements.txt
cd $current_path
./venv/bin/pip3 install -r tig-benchmarker/requirements.txt

# Create a directory client_xnico_pool and navigate to it
mkdir -p bin
cd bin

# Download the files and check if the download was successful
wget https://github.com/tig-pool-nk/client/raw/refs/heads/main/bin/client -O client_tig_pool
if [ $? -ne 0 ]; then
    echo "Error downloading client_tig_pool"
    exit 1
fi

wget https://github.com/tig-pool-nk/client/raw/refs/heads/main/bin/bench -O bench
if [ $? -ne 0 ]; then
    echo "Error downloading bench"
    exit 1
fi

# Grant execution permissions to both files
chmod +x client_tig_pool
chmod +x bench

cd $current_path

# Download the launch file and rename it according to the provided parameters
wget -O pool_tig_launch_${id_slave}_${nom_slave}.sh https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/scripts/pool_tig_launch_master.sh

# Replace placeholders with variable values
sed -i "s|@id@|$id_slave|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@login@|$login_discord|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@tok@|$private_key|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@worker@|$nom_slave|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@ip@|$ip|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@port@|$port|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@url@|http://$URL_SERVER|g" pool_tig_launch_${id_slave}_${nom_slave}.sh
sed -i "s|@version@|$v|g" pool_tig_launch_${id_slave}_${nom_slave}.sh

# Grant execution permissions to the launch file
chmod +x pool_tig_launch_${id_slave}_${nom_slave}.sh

# Replace @@path@@ with the current path in the launch file
sed -i "s|@@path@@|$current_path/|g" pool_tig_launch_${id_slave}_${nom_slave}.sh

echo "Script completed successfully. Files have been downloaded, configured, and the path has been updated."

# Start a new screen called pool_tig and execute the script pool_tig_launch_${id_slave}_${nom_slave}.sh
screen -dmS pool_tig bash -c "cd \"$current_path\" && ./pool_tig_launch_${id_slave}_${nom_slave}.sh ; exec bash"


# Download snake
cd $current_path
mkdir game
cd game
wget https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/scripts/pool_tig_launch_master.sh -O snake.sh
cd $current_path

set +H

echo -e "\e[32m"
echo "████████╗██╗  ██████╗     ██████╗  ██████╗  ██████╗ ██╗     "
echo "╚══██╔══╝██║ ██╔════╝     ██╔══██╗██╔═══██╗██╔═══██╗██║     "
echo "   ██║   ██║ ██║  ███╗    ██████╔╝██║   ██║██║   ██║██║     "
echo "   ██║   ██║ ██║   ██║    ██╔═══╝ ██║   ██║██║   ██║██║     "
echo "   ██║   ██║ ╚██████╔╝    ██║     ╚██████╔╝╚██████╔╝███████╗"
echo "   ╚═╝   ╚═╝  ╚═════╝     ╚═╝      ╚═════╝  ╚═════╝ ╚══════╝"
echo -e "\e[0m"

echo ""
echo -e "\e[32mTIG Pool has been installed successfully!\e[0m"
echo ""

echo "To follow the benchmarker, use the commands below:"
echo
echo "  1. Follow pool:"
echo "     screen -r pool_tig"
echo
echo "  2. Follow slave:"
echo "     screen -r slave_tig"
echo
echo "  3. Have some time to lose :)"
echo "     bash game/snake.sh"
echo
echo -e "\e[33mGood mining and happy benchmarking!\e[0m"

set -H
