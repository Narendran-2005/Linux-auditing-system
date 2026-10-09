#!/bin/bash
# systemd.sh - system performance (CPU, disk, network, load)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

header "System performance"

echo
header "1. CPU usage"
if have top; then
    top -b -n 1 | head -n 10
else
    warn "top not installed (package: procps)"
fi

echo
header "2. CPU statistics per core"
if have mpstat; then
    mpstat -P ALL 1 1
else
    warn "mpstat not installed (package: sysstat)"
fi

echo
header "3. Disk usage"
df -h

echo
header "4. Listening ports"
if have ss; then
    ss -tulnp
elif have netstat; then
    netstat -tuln
else
    warn "Neither ss nor netstat is installed (package: iproute2)"
fi

echo
header "5. Load average and uptime"
uptime