#!/bin/bash
# service.sh - running services and risky services that are enabled
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

header "Running services"
systemctl list-units --type=service --state=running --no-legend --plain \
    | awk '{print $1}' | sed 's/^/  /'

echo
header "Risky services"
risky=(
    telnet.socket
    rsh.socket
    rlogin.socket
    rexec.socket
    vsftpd.service
    proftpd.service
    tftp.service
    tftpd-hpa.service
    avahi-daemon.service
    cups.service
    cups-browsed.service
    rpcbind.service
    rpcbind.socket
    xinetd.service
)

found=0
for svc in "${risky[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        fail "$svc is running"
        found=1
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        warn "$svc is enabled but not running"
        found=1
    fi
done

(( found )) || pass "No risky services are active or enabled"