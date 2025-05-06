#!/bin/bash
set -e

CHECK_VERSION_URL="$1/mainnet/get-version"
UPDATE_INTERVAL=30
ENV_FILE=".tig_env"

check_and_update() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "[UPDATER] ERROR: Environment file '$ENV_FILE' not found."
        return
    fi

    source "$ENV_FILE"

    if [[ -z "$PATH" || -z "$ID_SLAVE" || -z "$MASTER" || -z "$LOGIN_DISCORD" || -z "$TOKEN" || -z "$MODE" || -z "$INSTALL_URL" ]]; then
        echo "[UPDATER] ERROR: One or more required environment variables are missing in $ENV_FILE"
        return
    fi

    LOCAL_VERSION=$(cat "./version.txt" 2>/dev/null || echo "0")
    REMOTE_VERSION=$(curl -fsS "$CHECK_VERSION_URL" || echo "")

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

        echo "[UPDATER] Relaunching installation from $INSTALL_URL"
        PARENT_PATH="${PATH%/*}"
        cd "$PARENT_PATH"
        bash <(wget --no-cache -qO- "$INSTALL_URL") "$ID_SLAVE" "$MASTER" "$LOGIN_DISCORD" "$TOKEN" "$REMOTE_VERSION" "$MODE" &

        exit 0
    else
        echo "[UPDATER] Version is up to date ($LOCAL_VERSION)"
    fi
}

while true; do
    check_and_update
    sleep "$UPDATE_INTERVAL"
done
