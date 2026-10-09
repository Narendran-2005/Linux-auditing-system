#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if have figlet; then
    figlet "Linux Auditing"
else
    echo "=== Linux Auditing ==="
fi