#!/usr/bin/env bash

cd "$(dirname "$0")" || exit
dockerComposeProfiles=""

while [ $# -gt 0 ]; do
  case "$1" in
  --profiles* | -p*)
    if [[ "$1" != *=* ]]; then shift; fi
    dockerComposeProfiles="${1#*=}"
    ;;
  *)
    printf >&2 "Error: Invalid argument: %s\n" "$1"
    exit 3
    ;;
  esac
  shift
done

if [ -z "$dockerComposeProfiles" ]; then
  dockerComposeProfiles="core"
fi

### run other services
echo "Resolved docker-compose profiles: $dockerComposeProfiles"
export COMPOSE_PROFILES="$dockerComposeProfiles"

./dc.sh up -d

unset COMPOSE_PROFILES
