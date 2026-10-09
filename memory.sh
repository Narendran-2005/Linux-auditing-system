#!/bin/bash
# memory.sh - memory and swap usage with simple warnings
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

header "Memory information"
have free && free -h

echo
header "/proc/meminfo (first 10 lines)"
head -n 10 /proc/meminfo

echo
header "Memory health"
mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
swap_total=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
swap_free=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)

if (( mem_avail * 100 / mem_total < 10 )); then
    warn "Less than 10% of memory is available"
else
    pass "Available memory is $(( mem_avail * 100 / mem_total ))% of total"
fi

if (( swap_total == 0 )); then
    warn "No swap is configured"
else
    swap_used=$(( swap_total - swap_free ))
    if (( swap_used * 100 / swap_total > 50 )); then
        warn "More than half of swap is in use"
    else
        pass "Swap usage is $(( swap_used * 100 / swap_total ))%"
    fi
fi