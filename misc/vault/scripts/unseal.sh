#!/bin/sh

vaultInitFile=$1

if [ -f "$vaultInitFile" ]; then
  echo "$(date -u +%FT%T.%3NZ) [INFO]  unseal.sh: Unsealing vault..."
  export VAULT_ADDR=http://localhost:8200

  unsealKey=$(jq -r '.unseal_keys_b64[0]' "$vaultInitFile")
  vault operator unseal "$unsealKey" > dev/null

  # Reset vault addr and add vault token
  vaultToken=$(jq -r '.root_token' "$vaultInitFile")
  export VAULT_TOKEN=$vaultToken
  vault token lookup

  else
    echo "$(date -u +%FT%T.%3NZ) [WARN]  unseal.sh: Vault initialization file is not found, can't be unsealed"
fi
