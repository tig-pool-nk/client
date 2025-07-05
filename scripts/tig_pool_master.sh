#!/bin/bash
set -euo pipefail

HAS_GPU=0

usage() {
    echo "Usage: $0 -id_slave <id_slave> -ip <ip> -login <login_discord> -tok <private_key> -url <URL_SERVER> -b <branch> -v <version> -no_setup <true|false>"
    exit 1
}

parse_args() {
    if [ "$#" -ne 16 ]; then
        usage
    fi

    id_slave=""
    ip=""
    v=""
    login_discord=""
    private_key=""
    URL_SERVER=""
    branch=""
    no_setup=false

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -id_slave) id_slave="$2"; shift 2 ;;
            -ip) ip="$2"; shift 2 ;;
            -v) v="$2"; shift 2 ;;
            -login) login_discord="$2"; shift 2 ;;
            -tok) private_key="$2"; shift 2 ;;
            -url) URL_SERVER="$2"; shift 2 ;;
            -b) branch="$2"; shift 2 ;;
            -no_setup) no_setup=$2; shift 2 ;;
            *) echo "Unknown parameter: $1"; usage ;;
        esac
    done

    if [ -z "$id_slave" ] || [ -z "$ip" ] || [ -z "$v" ] || [ -z "$login_discord" ] || [ -z "$private_key" ] || [ -z "$URL_SERVER" ] || [ -z "$branch" ]; then
        echo "Missing required parameters."
        usage
    fi

    current_path=$(pwd)

    echo "ID Slave: $id_slave"
    echo "IP: $ip"
    echo "Login: $login_discord"
    echo "Private Key: $private_key"
    echo "URL Server: $URL_SERVER"
    echo "Current path: $current_path"
    echo "Current branch: $branch"
    echo "Skip system setup: $no_setup"
}

install_docker() {
    echo "🔹 Installing Docker..."

    sudo apt update
    sudo apt install -y uidmap dbus-user-session curl

    if ! command -v docker > /dev/null; then
        echo "🔹 Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
    else
        echo "✅ Docker is already installed."
    fi

    if [ -S /run/docker.sock ]; then
        sudo chmod 666 /run/docker.sock
    fi

    if [ -S /var/run/docker.sock ]; then
        sudo chmod 666 /var/run/docker.sock
    fi

    echo "🔹 Adding current user to docker group..."
    if ! getent group docker >/dev/null; then
        sudo groupadd docker
    fi
    if ! groups $USER | grep -q '\bdocker\b'; then
        sudo usermod -aG docker $USER
        sg docker -c "echo 'Group changed to docker'"
    fi

    docker run --rm hello-world
}

install_nvidia_drivers() {
    if ! command -v nvidia-smi > /dev/null; then
        echo "🔹 Installing NVIDIA drivers..."
        sudo apt update
        sudo apt install -y ubuntu-drivers-common
        recommended_drivers=$(ubuntu-drivers devices | grep recommended | awk '{print $3}')
        if [ -n "$recommended_drivers" ]; then
            echo "🔹 Installing recommended NVIDIA drivers: $recommended_drivers"
            sudo apt install -y $recommended_drivers
        fi
        echo "🔹 You need to reboot your system to load NVIDIA drivers, then restart setup script..."
        exit 1
    else
        echo "✅ NVIDIA drivers are already installed."
    fi
}


setup_nvidia_cuda() {
    echo "🔹 Checking for NVIDIA GPU..."
    if lspci | grep -i nvidia > /dev/null; then
        echo "✅ NVIDIA GPU detected."
        HAS_GPU=1

        install_nvidia_drivers
        if ! command -v nvidia-smi > /dev/null; then
            echo "❌ NVIDIA drivers installation failed or system needs reboot."
            exit 1
        fi

        required_version="12.6.3"
        echo "🔹 Checking CUDA..."
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

            LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}
            echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
            echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
            export PATH=/usr/local/cuda/bin:$PATH
            export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}

            source ~/.bashrc

            echo "CUDA Toolkit successfully installed"
        fi

        if ! dpkg -l | grep -q nvidia-container-toolkit; then
            echo "🔹 Installing NVIDIA Container Toolkit..."
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
            sudo apt update
            sudo apt install -y nvidia-container-toolkit
        fi

        echo "🔹 Configuring Docker for NVIDIA runtime..."
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
        sudo sed -i 's/^[# ]*no-cgroups *= *.*/no-cgroups = false/' /etc/nvidia-container-runtime/config.toml

        echo "🔹 Testing NVIDIA Docker runtime..."
        docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu20.04 nvidia-smi
    else
        echo "❌ No NVIDIA GPU detected. Skipping GPU setup."
    fi
}

system_setup() {
    if [[ "$no_setup" != "true" ]]; then
        echo "🔹 Performing system-level setup..."
        sudo apt update
        sudo apt install -y screen wget curl gnupg lsb-release
        install_docker
        setup_nvidia_cuda
    else
        echo "⚠️ Skipping system setup as requested."
    fi
}

download_binaries() {
    echo "🔹 Downloading TIG Pool binaries..."

    mkdir -p logs bin $HOME/.tig/$branch/logs
    cd bin

    wget --no-cache "https://github.com/tig-pool-nk/client/raw/refs/heads/$branch/bin/client" -O client_tig_pool || { echo "Error downloading client_tig_pool binary"; exit 1; }
    wget --no-cache "https://github.com/tig-pool-nk/client/raw/refs/heads/$branch/bin/slave" -O slave || { echo "Error downloading slave binary"; exit 1; }
    wget --no-cache "https://github.com/tig-pool-nk/client/raw/refs/heads/$branch/bin/bench" -O bench || { echo "Error downloading bench binary"; exit 1; }

    chmod +x client_tig_pool slave bench

    cd ..
}

configure_launch_script() {
    echo "🔹 Configuring launch scripts..."

    wget --no-cache -O "pool_tig_launch_${id_slave}.sh" "https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/pool_tig_launch_master.sh" || { echo "Error downloading pool_tig_launch_master script"; exit 1; }
    wget --no-cache -O tig_update_watcher.sh "https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/$branch/scripts/tig_update_watcher.sh" || { echo "Error downloading tig_update_watcher script"; exit 1; }
    chmod +x tig_update_watcher.sh

    
    sed -i "s|@id@|$id_slave|g" pool_tig_launch_${id_slave}.sh
    sed -i "s|@login@|$login_discord|g" pool_tig_launch_${id_slave}.sh
    sed -i "s|@tok@|$private_key|g" pool_tig_launch_${id_slave}.sh
    sed -i "s|@ip@|$ip|g" pool_tig_launch_${id_slave}.sh
    sed -i "s|@url@|https://$URL_SERVER|g" pool_tig_launch_${id_slave}.sh
    sed -i "s|@version@|$v|g" pool_tig_launch_${id_slave}.sh
    sed -i "s|@branch@|$branch|g" pool_tig_launch_${id_slave}.sh
    sed -i "s|@@path@@|$current_path/|g" pool_tig_launch_${id_slave}.sh

    chmod +x "pool_tig_launch_${id_slave}.sh"
}

launch_benchmark() {
    echo "🔹 Launching TIG Pool benchmark in screen session..."
    screen -dmL -Logfile "$(pwd)/logs/pool_tig.log" -S pool_tig bash -c "cd \"$(pwd)\" && ./pool_tig_launch_${id_slave}.sh ; exec bash"
}

test_docker_runtime() {
    echo "🔹 Testing Docker runtime..."

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
}

display_final_message() {
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

    echo "  Follow miner:"
    echo "     tail -f ~/tig_pool_main/logs/pool_tig.log"
    echo
    echo
    echo -e "\e[33mGood mining and happy benchmarking!\e[0m"
}

main() {
    parse_args "$@"
    system_setup
    test_docker_runtime
    download_binaries
    configure_launch_script
    launch_benchmark
    display_final_message
}

main "$@"
