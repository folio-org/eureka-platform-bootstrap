#!/usr/bin/env bash

cd "$(dirname "$0")" || exit

vaultToken=$(sh ./get-vault-token.sh)

envLocalConfig="../.env.local.credentials"

if [ ! -f "$envLocalConfig" ]; then
  touch "$envLocalConfig"
fi

if grep -q '^export SECRET_STORE_VAULT_TOKEN=' "$envLocalConfig"; then
  sed -ri 's/^(export SECRET_STORE_VAULT_TOKEN=)(.+)$/\1'"$vaultToken"'/' $envLocalConfig
else
  if [ -s "$nevLocalConfig" ]; then
    echo >> "$envLocalConfig"
  fi
  echo "# Populated vault token" >> "$envLocalConfig"
  echo "export SECRET_STORE_VAULT_TOKEN=$vaultToken" >> "$envLocalConfig"
fi
