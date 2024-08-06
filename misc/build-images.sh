#!/usr/bin/env bash

cd "$(dirname "$0")" || exit

echo "Building Vault image..."
cd vault
docker build -t folio-vault:1.13.3 .
