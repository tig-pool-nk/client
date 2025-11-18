#!/bin/bash

echo "=== TIG Pool Reinstallation Script ==="
echo ""

echo "Requesting sudo access..."
sudo -v
echo ""

echo "Checking GitHub connectivity..."
http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/install.sh)
if [ "$http_code" = "200" ]; then
    echo "GitHub is accessible"
    echo ""

    set -e

    cd ~
    echo "Working directory: $(pwd)"
    echo ""

    config_ok=false

    if [ -d "tig_pool_main" ]; then
        cd tig_pool_main
        echo "Entering tig_pool_main"
        echo ""

        launch_file=$(ls pool_tig_launch*.sh 2>/dev/null | head -n 1)

        if [ -n "$launch_file" ]; then
            echo "Configuration file found: $launch_file"
            echo ""

            id_slave=$(grep '^id_slave=' "$launch_file" | cut -d'"' -f2)
            login_discord=$(grep '^login_discord=' "$launch_file" | cut -d'"' -f2)
            token_private=$(grep '^token_private=' "$launch_file" | cut -d'"' -f2)
            version="61"
            branch=$(grep '^branch=' "$launch_file" | cut -d'"' -f2)
            ip=$(grep '^ip=' "$launch_file" | cut -d'"' -f2)

            if [ -n "$id_slave" ] && [ -n "$login_discord" ] && [ -n "$token_private" ] && [ -n "$branch" ]; then
                echo "Retrieved variables:"
                echo "   ID Slave: $id_slave"
                echo "   Login Discord: $login_discord"
                echo "   Token: $token_private"
                echo "   Version: $version"
                echo "   Branch: $branch"
                echo "   IP/Server: $ip"
                echo ""
                config_ok=true
            else
                echo "Error: Could not retrieve all variables from config file"
                echo "Please launch installation from the TIG Pool dashboard link"
            fi
        else
            echo "No configuration file found"
            echo "Please launch installation from the TIG Pool dashboard link"
        fi
        cd ~
    else
        echo "tig_pool_main folder not found"
        echo "Please launch installation from the TIG Pool dashboard link"
    fi

    if [ "$config_ok" = true ]; then
        cd ~
        echo "Returning to home directory"
        echo ""

        echo "Killing tig_runtime processes..."
        pkill tig_runtime 2>/dev/null || true
        echo "Processes killed"
        echo ""

        echo "Removing old tig_pool* folders..."
        sudo rm -rf tig_pool* 2>&1 | grep -v "cannot remove" || true
        echo "Folders removed"
        echo ""

        echo "Launching installation with parameters:"
        echo "   bash <(wget --no-cache -qO- https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/install.sh) \\"
        echo "     $id_slave $ip $login_discord $token_private $version $branch"
        echo ""

        bash <(wget --no-cache -qO- https://raw.githubusercontent.com/tig-pool-nk/client/refs/heads/main/install.sh) \
            "$id_slave" "$ip" "$login_discord" "$token_private" "$version" "$branch"
        echo ""
        echo "Installation completed!"
    fi
else
    echo "GitHub is down, try later"
fi
