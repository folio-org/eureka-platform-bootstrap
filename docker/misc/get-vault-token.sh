#!/usr/bin/env bash

cd "$(dirname "$0")" || exit

docker logs vault 2> /dev/null \
  | grep "Root VAULT TOKEN is:" \
  | sed -E 's/^.*Root VAULT TOKEN is: (.+)$/\1/'
