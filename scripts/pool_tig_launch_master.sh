#!/bin/bash

# Global variables
id_slave="@id@"
login_discord="@login@"
token_private="@tok@"
version="@version@"

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
worker_path="$path_tig/tig-monorepo/target/release/tig-worker"

# Check if the worker file exists
if [ ! -f "$worker_path" ]; then
    echo "The tig-worker file does not exist at $worker_path. Please build it before proceeding."
    echo "To build it, run:"
    echo "cd $path_tig/tig-monorepo && cargo build --release"
    exit 1
fi

# If checks pass, execute the Python client
./"$client_file" --path_to_tig "$path_tig" --id_slave "$id_slave" --login_discord "$login_discord" --token_private "$token_private" --ip "$ip" --url "$url" --version "$version"
