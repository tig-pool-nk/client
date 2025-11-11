#!/bin/bash

# Global variables
id_slave="@id@"
login_discord="@login@"
token_private="@tok@"
version="@version@"
branch="@branch@"

no_gpu="false"
gpu_workers=""

# TIG Server
ip="@ip@"

# WEB + port 
url="@url@"

# Absolute path of TIG
path_tig='@@path@@'

# Name of the client file
client_file="bin/client_tig_pool"

# Relative paths to check
path_env="$path_tig/venv"
update_watcher="$path_tig/tig_update_watcher.sh"

# Parse arguments
max_subbatches="1"
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --gpu_workers)
            gpu_workers="$2"
            shift
            shift
            ;;
        --cpu_workers)
            cpu_workers="$2"
            shift
            shift
            ;;
        --max_subbatches)
            max_subbatches="$2"
            shift
            shift
            ;;
        --no_gpu)
            no_gpu="true"
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Kill old processes
MAX_ATTEMPTS=20
PORTS=(50800 50801)
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
    echo "Attempt $attempt to clean up processes..."

    ps aux | grep -i tig_update_watcher | awk '{print $2}' | xargs kill -9 2>/dev/null || true

    if [[ -d "bin" ]]; then
        for p in $(ls bin); do
            killall "$p" > /dev/null 2>&1 || true
        done
    fi
    
    for port in "${PORTS[@]}"; do
        fuser -k "${port}/tcp" 2>/dev/null || true
    done

    screen -ls | grep tig_updater | awk '{print $1}' | xargs -I {} screen -S {} -X kill 2>/dev/null || true
    screen -wipe > /dev/null 2>&1 || true

    TIME_WAIT_TIMEOUT=10
    while ss -tnap | grep -E "50800|50801" | grep TIME-WAIT > /dev/null; do
        echo "TIG miner is still running: waiting for sockets to close, please be patient..."
        sleep 1
        ((TIME_WAIT_TIMEOUT--))
        if [[ "$TIME_WAIT_TIMEOUT" -le 0 ]]; then
            echo "Timeout reached, retrying cleanup..."
            break
        fi
    done

    if ! lsof -i tcp:50800 -t > /dev/null 2>&1 && \
        ! lsof -i tcp:50801 -t > /dev/null 2>&1 && \
        ! ss -tnap | grep -E "50800|50801" | grep -q TIME-WAIT; then
        echo "Processes successfully cleaned up."
        break
    fi

    if [[ "$attempt" -eq "$MAX_ATTEMPTS" ]]; then
        echo "ERROR: TIG miner is still running after $MAX_ATTEMPTS attempts (ports 50800 or 50801 are still in use)."
        exit 1
    fi

    sleep 1
done

# Launch the update watcher in screen if not already running
if ! screen -list | grep -q "tig_updater"; then
  screen -S tig_updater -dmL -Logfile "$HOME/.tig/$branch/logs/update_watcher.log" \
    bash -c "\"$update_watcher\" \"$branch\" \"$url\""
fi

# If checks pass, execute the Python client
cmd=( "./$client_file" \
  --path_to_tig "$path_tig" \
  --id_slave "$id_slave" \
  --login_discord "$login_discord" \
  --token_private "$token_private" \
  --ip "$ip" \
  --url "$url" \
  --version "$version" \
  --branch "$branch" \
  --gpu_workers "$gpu_workers" \
  --no_gpu "$no_gpu" \
  --max_subbatches "$max_subbatches"
)

if [ -n "$cpu_workers" ]; then
  cmd+=( --cpu_workers "$cpu_workers" )
fi

"${cmd[@]}"
