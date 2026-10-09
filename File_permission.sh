#!/bin/bash
# File_permission.sh - checks sensitive files against the maximum allowed mode
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

header "Checking file permissions"

# Maximum allowed mode per file. Any bit set beyond this is a finding.
declare -A max_mode=(
    [/etc/shadow]=640
    [/etc/gshadow]=640
    [/etc/passwd]=644
    [/etc/group]=644
    [/etc/sudoers]=440
    [/etc/crypttab]=600
    [/etc/fstab]=644
    [/etc/hosts]=644
    [/etc/hostname]=644
    [/root]=700
)

files=(
    /etc/shadow
    /etc/gshadow
    /etc/passwd
    /etc/group
    /etc/sudoers
    /etc/crypttab
    /etc/fstab
    /etc/hosts
    /etc/hostname
    /root
)

for f in "${files[@]}"; do
    if [[ ! -e "$f" ]]; then
        warn "$f not found (skipped)"
        continue
    fi

    read -r mode owner <<< "$(stat -c '%a %U:%G' "$f")"
    allowed=$((8#${max_mode[$f]}))
    actual=$((8#$mode))
    extra=$(( actual & ~allowed & 0777 ))

    if (( extra != 0 )); then
        fail "$f has mode $mode (maximum allowed: ${max_mode[$f]})"
    else
        pass "$f has mode $mode (maximum allowed: ${max_mode[$f]})"
    fi

    if [[ "$owner" == root:* ]]; then
        info "owner $owner"
    else
        fail "$f is owned by $owner (expected root)"
    fi
done