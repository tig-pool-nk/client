#!/bin/bash
set -e

BRANCH=$1
CHECK_VERSION_URL="$2/mainnet/get-version"
UPDATE_INTERVAL=1800
ENV_FILE="$HOME/.tig/$BRANCH/.tig_env"

MAX_ATTEMPTS=20
PORTS=(50800 50801)

check_and_update() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "[UPDATER] ERROR: Environment file '$ENV_FILE' not found."
        return
    fi

    source "$ENV_FILE"

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

        PARENT_PATH="${TIG_PATH%/*}"
        cd "$PARENT_PATH"
        echo "[UPDATER] Relaunching installation from $INSTALL_URL into dir $PARENT_PATH"

        install_script_path="$HOME/.tig/$BRANCH/install_temp.sh"
        wget --no-cache -qO "$install_script_path" "$INSTALL_URL"
        chmod +x "$install_script_path"

        screen -S tig_reinstall -dmL -Logfile "$HOME/.tig/$BRANCH/logs/auto_reinstall.log" bash -c "$install_script_path \"$ID_SLAVE\" \"$MASTER\" \"$LOGIN_DISCORD\" \"$TOKEN\" \"$REMOTE_VERSION\" \"$MODE\" --no-system-setup"
        
        sleep 5
        exit 0
    else
        echo "[UPDATER] Version is up to date ($LOCAL_VERSION)"
    fi
}

echo "[UPDATER] Starting TIG updater..."
while true; do
    check_and_update
    sleep "$UPDATE_INTERVAL"
done
