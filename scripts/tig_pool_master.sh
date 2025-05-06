#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 -id_slave <id_slave> -ip <ip> -login <login_discord> -tok <private_key> -url <URL_SERVER> -b <branch>"
    exit 1
}

# Check if the total number of arguments ok
if [ "$#" -ne 14 ]; then
    usage
fi


# Check the number of processor threads
cpu_threads=$(grep -c ^processor /proc/cpuinfo)
if [ "$cpu_threads" -lt 24 ]; then
    echo "Your system has less than 24 threads ($cpu_threads detected). Installation aborted. You are not able to mine on TIGPool."
    exit 1
fi


# Initialize variables for parameters
id_slave=""
ip=""
v=""
login_discord=""
private_key=""
URL_SERVER=""
branch=""

# Parse input arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -id_slave)
            id_slave="$2"
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
        -b)
            branch="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            usage
            ;;
    esac
done

# Ensure variables are not empty
if [ -z "$id_slave" ] || [ -z "$ip" ] ||  [ -z "$login_discord" ] || [ -z "$private_key" ] || [ -z "$URL_SERVER" ]|| [ -z "$branch" ]; then
    usage
fi

current_path=$(pwd)

# Display parameters (or execute other logic with these values)
echo "ID Slave: $id_slave"
echo "IP: $ip"
echo "Login: $login_discord"
echo "Private Key: $private_key"
echo "URL Server: $URL_SERVER"
echo "Current path: $current_path"
echo "Current branch: $branch"

if sudo -n true 2>/dev/null || [ -t 0 ]; then
  echo "Performing system-level setup..."
  sudo apt update
  sudo apt install -y build-essential cargo curl tmux git libssl-dev pkg-config screen

  if ! command -v rustup >/dev/null 2>&1; then
    echo "Installing Rust toolchain..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  fi
else
  echo "Skipping system setup (non-interactive or no sudo access)."
fi

source "$HOME/.cargo/env"

# Create the directory tig_pool_test and navigate to it
mkdir -p wasms
mkdir -p logs
mkdir -p $HOME/.tig/$branch/logs

# Clone the Git repository with the specified branch
git clone -b $branch https://github.com/tig-pool-nk/tig-monorepo.git

# Navigate to the benchmarker directory and build the project with cargo
cd tig-monorepo/tig-worker/
cargo build -p tig-worker --release

# Install the benchmarker
cd $current_path

# Create a directory client_xnico_pool and navigate to it
mkdir -p bin
cd bin

# Download the files and check if the download was successful
wget --no-cache https://github.com/tig-pool-nk/client/raw/refs/heads/$branch/bin/client -O client_tig_pool
if [ $? -ne 0 ]; then
    echo "Error downloading client_tig_pool"
    exit 1
fi

wget https://github.com/tig-pool-nk/client/raw/refs/heads/$branch/bin/slave -O slave
if [ $? -ne 0 ]; then
    echo "Error downloading slave"
    exit 1
fi

wget https://github.com/tig-pool-nk/client/raw/refs/heads/$branch/bin/bench -O bench
if [ $? -ne 0 ]; then
    echo "Error downloading bench"
    exit 1
fi

# Grant execution permissions to both files
chmod +x client_tig_pool
chmod +x bench
chmod +x slave

cd $current_path

# Download the launch file and rename it according to the provided parameters
wget --no-cache -O pool_tig_launch_${id_slave}.sh https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/pool_tig_launch_master.sh

# Download updater script
wget --no-cache -O tig_update_watcher.sh https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/tig_update_watcher.sh
chmod +x tig_update_watcher.sh

# Replace placeholders with variable values
sed -i "s|@id@|$id_slave|g" pool_tig_launch_${id_slave}.sh
sed -i "s|@login@|$login_discord|g" pool_tig_launch_${id_slave}.sh
sed -i "s|@tok@|$private_key|g" pool_tig_launch_${id_slave}.sh
sed -i "s|@ip@|$ip|g" pool_tig_launch_${id_slave}.sh
sed -i "s|@url@|https://$URL_SERVER|g" pool_tig_launch_${id_slave}.sh
sed -i "s|@version@|$v|g" pool_tig_launch_${id_slave}.sh
sed -i "s|@branch@|$branch|g" pool_tig_launch_${id_slave}.sh

# Grant execution permissions to the launch file
chmod +x pool_tig_launch_${id_slave}.sh

# Replace @@path@@ with the current path in the launch file
sed -i "s|@@path@@|$current_path/|g" pool_tig_launch_${id_slave}.sh

echo "Script completed successfully. Files have been downloaded, configured, and the path has been updated."


pkill -f slave_tig && pkill -f pool_tig*
screen -wipe >/dev/null 2>&1 || true

# Start a new screen called pool_tig and execute the script pool_tig_launch_${id_slave}.sh
screen -dmL -Logfile "$current_path/logs/pool_tig.log" -S pool_tig bash -c "cd \"$current_path\" && ./pool_tig_launch_${id_slave}.sh ; exec bash"



# Download snake
cd $current_path
mkdir game
cd game
wget --no-cache https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/snake.sh -O snake.sh
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
echo -e "\e[32mTIG $branch Pool has been installed successfully!\e[0m"
echo ""

echo "To follow the benchmarker, use the commands below:"
echo

echo "  1. Follow pool:"
echo "     tail -f ~/tig_pool_main/logs/pool_tig.log"
echo
echo "  2. Have some time to lose :)"
echo "     bash ~/tig_pool_main/game/snake.sh"
echo
echo -e "\e[33mGood mining and happy benchmarking!\e[0m"

set -H
