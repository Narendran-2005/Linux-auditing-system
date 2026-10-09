#!/bin/bash
# process.sh - zombie and I/O-blocked processes
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

header "Process monitoring"

# Run ps once and reuse the output
ps_out=$(ps -eo pid,stat,user,comm --no-headers)

printf -v hdr "%-8s %-8s %-12s %s" "PID" "STAT" "USER" "COMMAND"

zombies=$(awk '$2 ~ /^[ZX]/' <<< "$ps_out")
if [[ -z "$zombies" ]]; then
    pass "No zombie processes found"
else
    fail "Zombie processes found"
    echo "$hdr"
    awk '{printf "%-8s %-8s %-12s %s\n", $1, $2, $3, $4}' <<< "$zombies"
fi

blocked=$(awk '$2 ~ /^D/' <<< "$ps_out")
if [[ -z "$blocked" ]]; then
    pass "No processes waiting for I/O"
else
    warn "Processes in uninterruptible I/O wait (state D) may indicate a disk bottleneck"
    echo "$hdr"
    awk '{printf "%-8s %-8s %-12s %s\n", $1, $2, $3, $4}' <<< "$blocked"
fi