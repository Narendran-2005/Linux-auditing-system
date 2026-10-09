#!/bin/bash
# File_system.sh - checks key directories are separate mounts with safe options
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

header "File system"

# Expected mount options per directory
declare -A required_opts=(
    [/tmp]="nodev nosuid noexec"
    [/var/tmp]="nodev nosuid noexec"
    [/home]="nodev nosuid"
    [/var/log]="nodev nosuid noexec"
)

for dir in /home /tmp /var/tmp /var/lib /var/log; do
    if [[ -L "$dir" ]]; then
        warn "$dir is a symbolic link pointing to $(readlink -f "$dir")"
        continue
    fi

    if [[ ! -d "$dir" ]]; then
        warn "$dir does not exist"
        continue
    fi

    if ! findmnt -rn --mountpoint "$dir" >/dev/null 2>&1; then
        warn "$dir is NOT a separate mount point (shares the root filesystem)"
        continue
    fi

    opts=$(findmnt -rn -o OPTIONS --mountpoint "$dir")
    pass "$dir is a separate mount point ($opts)"

    for opt in ${required_opts[$dir]:-}; do
        if [[ ",$opts," == *",$opt,"* ]]; then
            info "$opt is set on $dir"
        else
            fail "$dir is missing the '$opt' mount option"
        fi
    done
done