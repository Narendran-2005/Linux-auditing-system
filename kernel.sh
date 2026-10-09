#!/bin/bash
# kernel.sh - checks kernel hardening parameters against recommended values
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

# Format: key|recommended value|mode
#   eq  = must match exactly
#   min = must be greater than or equal to the value
checks=(
    "net.ipv4.ip_forward|0|eq"
    "net.ipv4.conf.all.accept_redirects|0|eq"
    "net.ipv4.conf.all.send_redirects|0|eq"
    "net.ipv4.conf.all.accept_source_route|0|eq"
    "net.ipv4.conf.all.rp_filter|1|eq"
    "net.ipv4.tcp_syncookies|1|eq"
    "net.ipv4.icmp_echo_ignore_broadcasts|1|eq"
    "kernel.randomize_va_space|2|eq"
    "kernel.dmesg_restrict|1|eq"
    "kernel.kptr_restrict|1|min"
    "kernel.yama.ptrace_scope|1|min"
    "fs.suid_dumpable|0|eq"
    "fs.protected_hardlinks|1|eq"
    "fs.protected_symlinks|1|eq"
)

header "Kernel information"
info "Kernel release: $(uname -r)"
echo

header "Hardening parameters"
for entry in "${checks[@]}"; do
    IFS='|' read -r key want mode <<< "$entry"

    if ! got=$(sysctl -n "$key" 2>/dev/null); then
        warn "$key is not available on this kernel"
        continue
    fi

    if [[ "$mode" == "min" ]]; then
        (( got >= want )) && good=1 || good=0
        rec=">= $want"
    else
        [[ "$got" == "$want" ]] && good=1 || good=0
        rec="$want"
    fi

    if (( good )); then
        pass "$key = $got"
    else
        fail "$key = $got (recommended: $rec)"
    fi
done