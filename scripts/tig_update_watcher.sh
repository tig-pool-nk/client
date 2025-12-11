#!/bin/bash
set -e

download_and_verify_md5() {
    local url="$1"
    local output_file="${2:-$(basename "$url")}"
    local md5_url="${url}.md5"
    local md5_file="${output_file}.md5"

    echo "[UPDATER] Downloading $output_file..."
    if ! wget --no-cache -q -O "$output_file" "$url"; then
        echo "[UPDATER] ERROR: Failed to download $url"
        return 1
    fi

    echo "[UPDATER] Downloading MD5 checksum..."
    if ! wget --no-cache -q -O "$md5_file" "$md5_url"; then
        echo "[UPDATER] ERROR: Failed to download MD5 checksum from $md5_url"
        rm -f "$output_file"
        return 1
    fi

    echo "[UPDATER] Verifying MD5 checksum..."
    local expected_md5=$(awk '{print $1}' "$md5_file")
    local actual_md5=$(md5sum "$output_file" | awk '{print $1}')

    if [ "$expected_md5" != "$actual_md5" ]; then
        echo "[UPDATER] ERROR: MD5 checksum verification failed for $output_file"
        echo "[UPDATER]    Expected: $expected_md5"
        echo "[UPDATER]    Actual:   $actual_md5"
        rm -f "$output_file" "$md5_file"
        return 1
    fi

    echo "[UPDATER] MD5 checksum verified for $output_file"
    rm -f "$md5_file"
    return 0
}

BRANCH=$1
URL=$2
CHECK_VERSION_URL="$2/mainnet/get-version"
UPDATE_INTERVAL=900
ENV_FILE="$HOME/.tig/$BRANCH/.tig_env"

MAX_ATTEMPTS=20
PORTS=(50800 50801)

check_script_update() {
    if [[ "$BRANCH" == "test" ]]; then
        local BASE_URL="https://download-test.tigpool.com"
    else
        local BASE_URL="https://download.tigpool.com"
    fi
    local SCRIPT_URL="$BASE_URL/scripts/tig_update_watcher.sh"
    local CURRENT_SCRIPT="$TIG_PATH/tig_update_watcher.sh"
    local TEMP_SCRIPT="$TIG_PATH/tig_update_watcher.sh.update"

    # Download the remote version
    if ! wget --no-cache -q -O "$TEMP_SCRIPT" "$SCRIPT_URL" 2>/dev/null; then
        echo "[UPDATER] Failed to download script update, continuing with current version"
        \rm -f "$TEMP_SCRIPT" 2>/dev/null || true
        return 1
    fi

    # Compare the files
    if ! cmp -s "$CURRENT_SCRIPT" "$TEMP_SCRIPT"; then
        echo "[UPDATER] New script version detected, updating and restarting..."
        \chmod +x "$TEMP_SCRIPT"
        \mv "$TEMP_SCRIPT" "$CURRENT_SCRIPT"

        # Restart the script
        echo "[UPDATER] Restarting updater with new version..."
        exec "$CURRENT_SCRIPT" "$BRANCH" "$URL"
    else
        \rm -f "$TEMP_SCRIPT" 2>/dev/null || true
    fi

    return 0
}

launch_benchmark() {
    echo "🔹 Launching TIG Pool benchmark in screen session..."
    id_slave=$1

    # Load runtime parameters from .tig_env if they exist
    RUNTIME_FILE="$HOME/.tig/$BRANCH/.env.runtime"
    RUNTIME_PARAMS=""

    if [[ -f "$RUNTIME_FILE" ]]; then
        source "$RUNTIME_FILE"

        # Build runtime parameters string
        if [[ -n "${GPU_WORKERS:-}" ]]; then
            RUNTIME_PARAMS="$RUNTIME_PARAMS --gpu_workers \"$GPU_WORKERS\""
        fi

        if [[ -n "${CPU_WORKERS:-}" ]]; then
            RUNTIME_PARAMS="$RUNTIME_PARAMS --cpu_workers \"$CPU_WORKERS\""
        fi

        if [[ -n "${MAX_SUBBATCHES:-}" && "${MAX_SUBBATCHES}" != "1" ]]; then
            RUNTIME_PARAMS="$RUNTIME_PARAMS --max_subbatches \"$MAX_SUBBATCHES\""
        fi

        if [[ "${NO_GPU:-false}" == "true" ]]; then
            RUNTIME_PARAMS="$RUNTIME_PARAMS --no_gpu"
        fi
    fi

    # Launch with runtime parameters if any
    if [[ -n "$RUNTIME_PARAMS" ]]; then
        echo "🔹 Launching with runtime parameters: $RUNTIME_PARAMS"
        screen -dmL -Logfile "$(pwd)/logs/pool_tig.log" -S pool_tig bash -c "cd \"$(pwd)\" && ./pool_tig_launch_${id_slave}.sh $RUNTIME_PARAMS ; exec bash"
    else
        screen -dmL -Logfile "$(pwd)/logs/pool_tig.log" -S pool_tig bash -c "cd \"$(pwd)\" && ./pool_tig_launch_${id_slave}.sh ; exec bash"
    fi
}

check_and_update() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "[UPDATER] ERROR: Environment file '$ENV_FILE' not found."
        return
    fi

    if ! source "$ENV_FILE"; then
        echo "[UPDATER] ERROR: Cannot source $ENV_FILE"
        return
    fi

    if [[ -z "$TIG_PATH" || -z "$ID_SLAVE" || -z "$MASTER" || -z "$LOGIN_DISCORD" || -z "$TOKEN" || -z "$MODE" || -z "$INSTALL_URL" ]]; then
        echo "[UPDATER] ERROR: One or more required environment variables are missing in $ENV_FILE"
        return
    fi

    LOCAL_VERSION=$(cat "$HOME/.tig/$BRANCH/version.txt" 2>/dev/null || echo "")
    REMOTE_VERSION=$(curl -fsS "$CHECK_VERSION_URL" || echo "")

    if [[ -z "$LOCAL_VERSION" ]]; then
        echo "[UPDATER] No local version provided, skipping update check."
        return
    fi

    if [[ -z "$REMOTE_VERSION" || "$REMOTE_VERSION" == "None" || ! "$REMOTE_VERSION" =~ ^[0-9]+$ || "$REMOTE_VERSION" -le 0 ]]; then
        echo "[UPDATER] No remote version provided, skipping update check."
        return
    fi

    if [[ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]]; then
        echo "[UPDATER] New version available: $REMOTE_VERSION (local: $LOCAL_VERSION)"

        cd $TIG_PATH
        for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
            echo "[UPDATER] Attempt $attempt to clean up processes..."

            # Kill processes by name pattern (plus robuste que pgrep + awk + xargs)
            pkill -9 -f pool_tig_launch 2>/dev/null || true
            pkill -9 -f bin/client 2>/dev/null || true
            pkill -9 -f bin/slave 2>/dev/null || true
            pkill -9 -f bin/bench 2>/dev/null || true
            docker ps | grep tig | awk '{print $1}' | xargs -r docker stop || true
            pkill -9 -f batch_processor 2>/dev/null || true
            pkill -9 -f tig-runtime 2>/dev/null || true
            pkill -9 -f tig-verifier 2>/dev/null || true

            # Kill binaries
            if [[ -d "bin" ]]; then
                while IFS= read -r -d '' binary; do
                    pkill -9 -x "$(basename "$binary")" 2>/dev/null || true
                done < <(find bin -type f -executable -print0)
            fi

            # Force close ports
            for port in "${PORTS[@]}"; do
                fuser -k -TERM "${port}/tcp" 2>/dev/null || true
            done
            sleep 1
            for port in "${PORTS[@]}"; do
                fuser -k -KILL "${port}/tcp" 2>/dev/null || true
            done

            # Kill screen sessions
            screen -ls | grep pool_tig | awk '{print $1}' | xargs -I {} screen -S {} -X kill 2>/dev/null || true
            screen -wipe > /dev/null 2>&1 || true

            # Wait for TIME-WAIT sockets to close
            TIME_WAIT_TIMEOUT=10
            while ss -tnap | grep -E "50800|50801" | grep TIME-WAIT > /dev/null; do
                echo "[UPDATER] TIG miner is still running: waiting for sockets to close, please be patient..."
                sleep 1
                ((TIME_WAIT_TIMEOUT--))
                if [[ "$TIME_WAIT_TIMEOUT" -le 0 ]]; then
                    echo "[UPDATER] Timeout reached, retrying cleanup..."
                    break
                fi
            done

            # Final check
            if ! lsof -i tcp:50800 -t > /dev/null 2>&1 && \
               ! lsof -i tcp:50801 -t > /dev/null 2>&1 && \
               ! ss -tnap | grep -E "50800|50801" | grep -q TIME-WAIT && \
               ! pgrep -f "bin/client|bin/slave|bin/bench" > /dev/null 2>&1; then
                echo "[UPDATER] Processes successfully cleaned up."
                break
            fi

            if [[ "$attempt" -eq "$MAX_ATTEMPTS" ]]; then
                echo "ERROR: TIG miner is still running after $MAX_ATTEMPTS attempts (ports 50800 or 50801 are still in use)."
                return
            fi

            # Kill screen sessions
            screen -wipe > /dev/null 2>&1 || true

            sleep 2
        done

        echo "[UPDATER] Downloading new binaries..."
        cd "$TIG_PATH/bin"

        if [[ "$BRANCH" == "test" ]]; then
            BIN_BASE_URL="https://download-test.tigpool.com"
        else
            BIN_BASE_URL="https://download.tigpool.com"
        fi

        declare -A BINARIES=(
            [bench]="$BIN_BASE_URL/bin/bench"
            [client_tig_pool]="$BIN_BASE_URL/bin/client"
            [slave]="$BIN_BASE_URL/bin/slave"
        )

        for file in "${!BINARIES[@]}"; do
            tmp_file="${file}.new"
            url="${BINARIES[$file]}"
            if ! download_and_verify_md5 "$url" "$tmp_file"; then
                echo "[UPDATER] ERROR: Failed to download or verify $file"
                return
            fi
        done

        for file in "${!BINARIES[@]}"; do
            tmp_file="${file}.new"
            if [[ ! -f "$tmp_file" ]]; then
                echo "[UPDATER] ERROR: $tmp_file not found after download"
                return
            fi
        done

        for file in "${!BINARIES[@]}"; do
            tmp_file="${file}.new"
            \rm -f "$file"
            \mv "$tmp_file" "$file"
            \chmod +x "$file" || true
        done

        cd "$TIG_PATH"
        if [[ "$BRANCH" == "test" ]]; then
            DOWNLOAD_BASE_URL="https://download-test.tigpool.com"
        else
            DOWNLOAD_BASE_URL="https://download.tigpool.com"
        fi
        wget --no-cache -q --show-progress -O pool_tig_launch_master.sh "$DOWNLOAD_BASE_URL/scripts/pool_tig_launch_master.sh" || { echo "[UPDATER] ERROR: Failed to download pool_tig_launch_master.sh"; return; }
        if [[ ! -f "pool_tig_launch_master.sh" ]]; then
            echo "[UPDATER] ERROR: pool_tig_launch_master.sh not found after download"
            return
        fi
        \rm -f pool_tig_launch_${ID_SLAVE}.sh
        \mv pool_tig_launch_master.sh "pool_tig_launch_${ID_SLAVE}.sh"
        \chmod +x "pool_tig_launch_${ID_SLAVE}.sh" || true

        echo "[UPDATER] Binaries updated successfully."

        echo "[UPDATER] Updating scripts"
        cd "$TIG_PATH"

        echo $REMOTE_VERSION > "$HOME/.tig/$BRANCH/version.txt"
        sed -i "s|@id@|$ID_SLAVE|g" pool_tig_launch_${ID_SLAVE}.sh
        sed -i "s|@login@|$LOGIN_DISCORD|g" pool_tig_launch_${ID_SLAVE}.sh
        sed -i "s|@tok@|$TOKEN|g" pool_tig_launch_${ID_SLAVE}.sh
        sed -i "s|@ip@|$MASTER|g" pool_tig_launch_${ID_SLAVE}.sh
        sed -i "s|@url@|https://$MASTER|g" pool_tig_launch_${ID_SLAVE}.sh
        sed -i "s|@version@|$REMOTE_VERSION|g" pool_tig_launch_${ID_SLAVE}.sh
        sed -i "s|@branch@|$BRANCH|g" pool_tig_launch_${ID_SLAVE}.sh
        sed -i "s|@@path@@|$TIG_PATH|g" pool_tig_launch_${ID_SLAVE}.sh


        echo "[UPDATER] Relaunching tig miner"
        cd "$TIG_PATH"
        launch_benchmark $ID_SLAVE
        exit 0
    fi
}

echo "[UPDATER] Starting TIG updater..."

# Load environment file once to get TIG_PATH
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

while true; do
    # Check for script updates before checking for binary updates
    check_script_update

    # Check and update binaries
    check_and_update

    sleep "$UPDATE_INTERVAL"
done
