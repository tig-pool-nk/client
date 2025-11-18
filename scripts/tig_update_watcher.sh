#!/bin/bash
set -e

BRANCH=$1
CHECK_VERSION_URL="$2/mainnet/get-version"
UPDATE_INTERVAL=900
ENV_FILE="$HOME/.tig/$BRANCH/.tig_env"

MAX_ATTEMPTS=20
PORTS=(50800 50801)

launch_benchmark() {
    echo "🔹 Launching TIG Pool benchmark in screen session..."
    id_slave=$1
    screen -dmL -Logfile "$(pwd)/logs/pool_tig.log" -S pool_tig bash -c "cd \"$(pwd)\" && ./pool_tig_launch_${id_slave}.sh ; exec bash"
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

            ps aux | grep -i pool_tig_launch | awk '{print $2}' | xargs kill -9 2>/dev/null || true
            if [[ -d "bin" ]]; then
                for p in $(ls bin); do
                    killall "$p" > /dev/null 2>&1 || true
                done
            fi

            ps aux | grep -i tig-runtime | awk '{print $2}' | xargs kill -9 2>/dev/null || true
            
            for port in "${PORTS[@]}"; do
                fuser -k "${port}/tcp" 2>/dev/null || true
            done

            screen -ls | grep pool_tig | awk '{print $1}' | xargs -I {} screen -S {} -X kill 2>/dev/null || true
            screen -wipe > /dev/null 2>&1 || true

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

            if ! lsof -i tcp:50800 -t > /dev/null 2>&1 && \
                ! lsof -i tcp:50801 -t > /dev/null 2>&1 && \
                ! ss -tnap | grep -E "50800|50801" | grep -q TIME-WAIT; then
                echo "[UPDATER] Processes successfully cleaned up."
                break
            fi

            if [[ "$attempt" -eq "$MAX_ATTEMPTS" ]]; then
                echo "ERROR: TIG miner is still running after $MAX_ATTEMPTS attempts (ports 50800 or 50801 are still in use)."
                return
            fi

            sleep 1
        done

        echo "[UPDATER] Downloading new binaries..."
        cd "$TIG_PATH/bin"

        declare -A BINARIES=(
            [bench]="https://github.com/tig-pool-nk/client/raw/refs/heads/main/bin/bench"
            [client_tig_pool]="https://github.com/tig-pool-nk/client/raw/refs/heads/main/bin/client"
            [slave]="https://github.com/tig-pool-nk/client/raw/refs/heads/main/bin/slave"
        )

        for file in "${!BINARIES[@]}"; do
            tmp_file="${file}.new"
            url="${BINARIES[$file]}"
            echo "[UPDATER] Downloading $file from $url..."
            wget --no-cache -q --show-progress -O "$tmp_file" "$url" || { echo "[UPDATER] ERROR: Failed to download $file"; return; }
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
        wget --no-cache -q --show-progress -O tig_update_watcher.sh.new https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/scripts/tig_update_watcher.sh || { echo "[UPDATER] ERROR: Failed to download tig_update_watcher.sh"; return; }
        if [[ ! -f "tig_update_watcher.sh.new" ]]; then
            echo "[UPDATER] ERROR: tig_update_watcher.sh.new not found after download"
            return
        fi
        \rm -f tig_update_watcher.sh
        \mv tig_update_watcher.sh.new "tig_update_watcher.sh"
        \chmod +x "tig_update_watcher.sh" || true


        wget --no-cache -q --show-progress -O pool_tig_launch_master.sh https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/scripts/pool_tig_launch_master.sh || { echo "[UPDATER] ERROR: Failed to download pool_tig_launch_master.sh"; return; }
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
while true; do
    check_and_update
    sleep "$UPDATE_INTERVAL"
done
