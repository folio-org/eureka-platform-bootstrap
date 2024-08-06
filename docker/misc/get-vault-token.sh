#!/usr/bin/env bash

cd "$(dirname "$0")" || exit

docker logs vault 2> /dev/null \
  | grep "Root VAULT TOKEN is:" \
  | sed -r 's/^.+ \[INFO]\s+init.sh: Root VAULT TOKEN is: (.+)$/\1/'
