#!/bin/bash
set -e

BRANCH=$1
CHECK_VERSION_URL="$2/mainnet/get-version"
UPDATE_INTERVAL=3600
ENV_FILE="$HOME/.tig/$BRANCH/.tig_env"

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

        if [[ -d "bin" ]]; then
            for p in $(ls bin); do
                killall "$p" > /dev/null 2>&1 || true
            done
        fi
        screen -ls | grep pool_tig | awk '{print $1}' | xargs -I {} screen -S {} -X kill

        echo "[UPDATER] Relaunching installation from $INSTALL_URL"
        PARENT_PATH="${TIG_PATH%/*}"
        cd "$PARENT_PATH"

        install_script_path="$HOME/.tig/$BRANCH/install_temp.sh"
        wget --no-cache -qO "$install_script_path" "$INSTALL_URL"
        chmod +x "$install_script_path"

        screen -S tig_reinstall -dmL -Logfile "$HOME/.tig/$BRANCH/logs/auto_reinstall.log" bash -c "$install_script_path \"$ID_SLAVE\" \"$MASTER\" \"$LOGIN_DISCORD\" \"$TOKEN\" \"$REMOTE_VERSION\" \"$MODE\""

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
