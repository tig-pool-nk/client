#!/bin/bash
set -euo pipefail

# Function to display usage
usage() {
    echo "Usage: $0 -id_slave <id_slave> -ip <ip> -login <login_discord> -tok <private_key> -url <URL_SERVER> -b <branch> -no_setup <no_setup>"
    exit 1
}

# Check if the total number of arguments ok
if [ "$#" -ne 16 ]; then
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
no_setup=false

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
        -no_setup)
            no_setup=$2
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            usage
            ;;
    esac
done

# Ensure variables are not empty
if [ -z "$id_slave" ] || [ -z "$ip" ] ||  [ -z "$login_discord" ] || [ -z "$private_key" ] || [ -z "$URL_SERVER" ] || [ -z "$branch" ] || [ -z "$v" ]; then
    echo "Missing required parameters"
    echo "id_slave='$id_slave', ip='$ip', login='$login_discord', tok='$private_key', url='$URL_SERVER', branch='$branch', v='$v'"
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
echo "Skip system setup: $no_setup"

if [[ "$no_setup" != "true" ]]; then
    echo "Performing system-level setup..."
    sudo apt update
    sudo apt install -y screen

    HAS_GPU=0

    # Check if Docker is installed
    if ! command -v docker > /dev/null; then
        echo "Docker not found. Installing Docker..."

        # Install rootless Docker using the official script
        sudo apt install -y uidmap curl
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh

        if ! command -v dockerd-rootless-setuptool.sh >/dev/null; then
            echo "❌ dockerd-rootless-setuptool.sh not found in PATH. You may need to relogin or set up the environment manually."
            exit 1
        fi

        dockerd-rootless-setuptool.sh install
        \rm get-docker.sh

    else
        # Docker is installed: check if it's usable without sudo
        if ! docker info > /dev/null 2>&1; then
            echo "Docker is installed but not usable without sudo. Please configure rootless Docker."
            exit 1
        else
            echo "Docker is already installed and usable without sudo."
        fi
    fi

    # Check if cuda is installed
    if command -v nvidia-smi > /dev/null; then
        echo "NVIDIA GPU detected"
        HAS_GPU=1

        required_version="12.6.3"

        if command -v nvcc > /dev/null; then
            cuda_version=$(nvcc --version | grep "release" | sed -E 's/.*release ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
            echo "CUDA detected: version $cuda_version"

            if [[ "$(printf '%s\n' "$required_version" "$cuda_version" | sort -V | head -n1)" != "$required_version" ]]; then
                echo "CUDA version $cuda_version is too old. Minimum required version is $required_version."
                exit 1
            else
                echo "CUDA version is compatible (>= $required_version)"
            fi
        else
            echo "CUDA is not installed. Installing latest CUDA version..."

            . /etc/os-release

            if [[ "$ID" == "ubuntu" ]]; then
                release=$(lsb_release -rs | sed 's/\.//')
                nvidia_repo="ubuntu$release"
            elif [[ "$ID" == "debian" ]]; then
                release=$(lsb_release -rs | cut -d. -f1)
                nvidia_repo="debian$release"
            else
                echo "❌ Unsupported OS: $ID"
                exit 1
            fi

            major=$(echo "$release" | cut -c1-2)
            if { [[ "$ID" == "ubuntu" && "$release" -lt 2204 ]]; } || { [[ "$ID" == "debian" && "$release" -lt 12 ]]; }; then
                echo "Auto-install only supported for Ubuntu >= 22.04 and Debian >= 12"
                exit 1
            fi

            echo "Installing latest CUDA Toolkit for $nvidia_repo..."

            sudo apt-get update
            sudo apt-get install -y wget gnupg lsb-release

            CUDA_KEYRING_PKG="cuda-keyring_1.1-1_all.deb"
            wget https://developer.download.nvidia.com/compute/cuda/repos/$nvidia_repo/x86_64/$CUDA_KEYRING_PKG
            sudo dpkg -i $CUDA_KEYRING_PKG
            rm -f $CUDA_KEYRING_PKG

            sudo apt-get update
            sudo apt-get install -y cuda-toolkit

            echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
            echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
            export PATH=/usr/local/cuda/bin:$PATH
            export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH

            source ~/.bashrc

            echo "CUDA Toolkit successfully installed"
        fi

        if ! dpkg -l | grep -q nvidia-container-toolkit; then
            echo "nvidia-container-toolkit is not installed: starting installation..."

            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
                sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

            curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

            sudo apt update
            sudo apt install -y nvidia-container-toolkit
        else
            echo "nvidia-container-toolkit is already installed."
        fi

        DAEMON_CONFIG="$HOME/.config/docker/daemon.json"
        NEED_RESTART=0
        if ! grep -q '"nvidia"' "$DAEMON_CONFIG" 2>/dev/null; then
            echo "Configuring Docker to use NVIDIA runtime..."
            mkdir -p "$(dirname "$DAEMON_CONFIG")"
            touch "$DAEMON_CONFIG"
            nvidia-ctk runtime configure --runtime=docker --config=$DAEMON_CONFIG
            NEED_RESTART=1
        else
            echo "NVIDIA runtime already present in Docker config."
        fi

        CONFIG_FILE="/etc/nvidia-container-runtime/config.toml"
        if ! grep -q "^no-cgroups *= *true" "$CONFIG_FILE" 2>/dev/null; then
            echo "Enabling 'no-cgroups' setting for NVIDIA container runtime..."
            sudo nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place
            NEED_RESTART=1
        else
            echo "'no-cgroups' is already enabled."
        fi

        if [[ "$NEED_RESTART" -eq 1 ]]; then
            echo "Restarting Docker service..."
            if systemctl --user status docker &> /dev/null; then
                systemctl --user restart docker
            else
                sudo systemctl restart docker
            fi
        else
            echo "No restart needed. Configuration already correct."
        fi

    else
        echo "No NVIDIA GPU detected — skipping CUDA check."
    fi

    if [[ "$HAS_GPU" -eq 1 ]]; then
        echo "Testing NVIDIA runtime with Docker..."
        if docker run --rm --runtime=nvidia nvidia/cuda:12.2.0-base-ubuntu20.04 nvidia-smi; then
            echo "✅ NVIDIA runtime test passed."
        else
            echo "❌ NVIDIA runtime test with Docker failed."
            exit 1
        fi
    else
        echo "Testing Docker with a lightweight container..."
        if docker run --rm hello-world > /dev/null; then
            echo "✅ Docker is working properly."
        else
            echo "❌ Docker test failed."
            exit 1
        fi
    fi


else
  echo "Skipping system setup (non-interactive or no sudo access)."
fi

# Create the directory tig_pool_test and navigate to it
mkdir -p logs
mkdir -p $HOME/.tig/$branch/logs

# Install the benchmarker
cd $current_path

# Create a directory client_xnico_pool and navigate to it
mkdir -p bin
cd bin

# Download the files and check if the download was successful
wget --no-cache https://github.com/tig-pool-nk/client/raw/refs/heads/$branch/bin/client -O client_tig_pool || { echo "Error downloading client_tig_pool binary"; exit 1; }
wget https://github.com/tig-pool-nk/client/raw/refs/heads/$branch/bin/slave -O slave || { echo "Error downloading slave binary"; exit 1; }
wget https://github.com/tig-pool-nk/client/raw/refs/heads/$branch/bin/bench -O bench || { echo "Error downloading bench binary"; exit 1; }

# Grant execution permissions to both files
chmod +x client_tig_pool
chmod +x bench
chmod +x slave

cd $current_path

# Download the launch file and rename it according to the provided parameters
wget --no-cache -O pool_tig_launch_${id_slave}.sh https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/pool_tig_launch_master.sh || { echo "Error downloading pool_tig_launch_master script"; exit 1; }

# Download updater script
wget --no-cache -O tig_update_watcher.sh https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/tig_update_watcher.sh || { echo "Error downloading tig_update_watcher script"; exit 1; }
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
