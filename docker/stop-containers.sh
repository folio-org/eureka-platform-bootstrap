#!/bin/bash
cd "$(dirname "$0")" || exit

### run and init database
./dc.sh rm -s -v
