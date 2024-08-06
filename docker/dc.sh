#!/usr/bin/env bash

cd "$(dirname "$0")" || exit

if [[ -f .env.local ]]; then
  source .env.local
fi

# Export the COMPOSE_FILE variable
export COMPOSE_FILE=$(find . -maxdepth 1 -name "*.yml" | paste -sd ";" -)

docker compose --project-name "folio-platform-minimal" "$@"
