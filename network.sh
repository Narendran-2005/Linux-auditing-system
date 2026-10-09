#!/bin/bash
# network.sh - passive network inspection with optional active scanning
#
# Passive checks (always run): listening sockets, connections, interfaces,
# promiscuous mode, routes, DNS, ARP table.
#
# Active scanning (only with -a or -l): host discovery and service detection
# with nmap. nmap is installed on demand through setup-deps.sh.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
set -u -o pipefail

TARGETS=()
PORTS=""
USE_LOCAL=0
live_file=""

cleanup() {
    [[ -n "$live_file" ]] && rm -f "$live_file"
    return 0
}
trap cleanup EXIT

indent() { sed 's/^/       /'; }

usage() {
    cat <<'EOF'
Usage: network.sh [options]

Passive checks always run: listening sockets, connections, interfaces,
routes, DNS and the IPv4 ARP table. Passive checks send no packets to
other hosts.

Options:
  -a TARGET   Add an active scan target. Accepts an IPv4 address (10.0.0.5),
              a range (10.0.0.5-20), a CIDR block (192.168.1.0/24, /16 to /32)
              or a hostname. Repeat -a for several targets.
  -l          Add the local subnet, detected from the default route.
  -p PORTS    Ports to scan, e.g. 22,80,443 or 1-1024.
              Default: nmap's top 1000 ports.
  -h          Show this help.

Only scan systems you own or have written permission to test.
EOF
}

# ---- Validation ------------------------------------------------------------

# Returns 0 for an IPv4 address, range, CIDR block (/16 to /32) or hostname
valid_target() {
    local t="$1" n
    local re_ip='^([0-9]{1,3}\.){3}[0-9]{1,3}(-[0-9]{1,3}|/[0-9]{1,2})?$'
    local re_host='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'

    if [[ "$t" =~ $re_ip ]]; then
        # Every number (octets, range end, prefix) must be 0-255
        for n in ${t//[^0-9]/ }; do
            (( 10#$n <= 255 )) || return 1
        done
        # Refuse blocks broader than /16 so a typo cannot scan a huge range
        if [[ "$t" == */* ]]; then
            n="${t##*/}"
            (( 10#$n >= 16 && 10#$n <= 32 )) || return 1
        fi
        return 0
    fi

    [[ "$t" =~ $re_host ]] && (( ${#t} <= 253 ))
}

valid_ports() {
    local p
    [[ "$1" =~ ^[0-9]+([,-][0-9]+)*$ ]] || return 1
    for p in ${1//[,-]/ }; do
        (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
    done
    return 0
}

# Prints the IPv4 CIDR of the interface that carries the default route
detect_local_subnet() {
    have ip || return 1
    local iface cidr
    iface=$(ip -4 route show default 2>/dev/null \
        | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    [[ -n "$iface" ]] || return 1
    cidr=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
        | awk '{print $4; exit}')
    [[ -n "$cidr" ]] || return 1
    echo "$cidr"
}

# ---- Passive checks --------------------------------------------------------

check_listening() {
    header "Listening sockets"
    if ! have ss; then warn "ss not installed (package: iproute2)"; return 0; fi

    ss -tulnp 2>/dev/null | indent

    # Listeners on all interfaces are reachable from the network
    local exposed count
    exposed=$(ss -tulnH 2>/dev/null \
        | awk '$5 ~ /^(0\.0\.0\.0|\*|\[::\]):/ {print $1, $5}')
    if [[ -n "$exposed" ]]; then
        count=$(grep -c . <<< "$exposed")
        warn "$count listener(s) bound to all interfaces"
        indent <<< "$exposed"
    else
        pass "No listener is bound to all interfaces"
    fi
    return 0
}

check_connections() {
    header "Established connections"
    if ! have ss; then warn "ss not installed (package: iproute2)"; return 0; fi

    local lines total
    lines=$(ss -tnp state established 2>/dev/null | tail -n +2)
    total=$(grep -c . <<< "$lines" || true)

    if (( total == 0 )); then
        pass "No established connections"
        return 0
    fi

    info "$total established connection(s)"
    head -n 20 <<< "$lines" | indent
    (( total > 20 )) && warn "Showing 20 of $total connections"
    return 0
}

check_interfaces() {
    header "Interfaces"
    have ip || { warn "ip not installed (package: iproute2)"; return 0; }

    ip -brief addr 2>/dev/null | indent

    local path iface details
    for path in /sys/class/net/*; do
        [[ -e "$path" ]] || continue
        iface=${path##*/}
        [[ "$iface" == "lo" ]] && continue

        details=$(ip -o link show dev "$iface" 2>/dev/null)
        if [[ "$details" == *PROMISC* ]]; then
            fail "$iface is in promiscuous mode (possible packet capture)"
        else
            pass "$iface is not in promiscuous mode"
        fi
    done
    return 0
}

check_routes() {
    header "Routing and DNS"

    if have ip; then
        local routes
        routes=$(ip -4 route show default 2>/dev/null)
        if [[ -n "$routes" ]]; then
            indent <<< "$routes"
        else
            warn "No default IPv4 route"
        fi
    fi

    if [[ -r /etc/resolv.conf ]]; then
        local ns
        ns=$(awk '$1 == "nameserver" {print $2}' /etc/resolv.conf)
        if [[ -n "$ns" ]]; then
            info "DNS servers: $(paste -sd' ' - <<< "$ns")"
        else
            warn "No nameservers in /etc/resolv.conf"
        fi
    else
        warn "/etc/resolv.conf is not readable"
    fi
    return 0
}

check_arp() {
    header "ARP neighbours (IPv4)"
    have ip || { warn "ip not installed (package: iproute2)"; return 0; }

    local neigh
    neigh=$(ip -4 neigh show 2>/dev/null | grep -v FAILED || true)
    if [[ -z "$neigh" ]]; then
        info "No ARP entries"
        return 0
    fi
    indent <<< "$neigh"

    # Entries look like: 192.168.1.1 dev eth0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
    # A MAC shared by several IPv4 addresses is a WARN: routers with several
    # addresses and VRRP/HSRP do this legitimately.
    local shared
    shared=$(awk '$4 == "lladdr" {print $5, $1}' <<< "$neigh" | sort -u \
        | awk '{ count[$1]++; ips[$1] = ips[$1] " " $2 }
               END { for (m in count) if (count[m] > 1) print m ":" ips[m] }')

    if [[ -n "$shared" ]]; then
        warn "MAC address shared by several IPv4 addresses (possible ARP spoofing or redundancy such as VRRP):"
        indent <<< "$shared"
    else
        pass "No MAC address is shared by several IPv4 addresses"
    fi
    return 0
}

# ---- Active scanning -------------------------------------------------------

ensure_nmap() {
    have nmap && return 0

    local setup="$DIR/setup-deps.sh"
    if [[ -f "$setup" ]]; then
        # Asks for permission, then installs. The tag 'active-scan' selects only nmap.
        bash "$setup" active-scan || true
    fi

    if ! have nmap; then
        fail "nmap is required for active scans and is not installed"
        return 1
    fi
    return 0
}

run_active_scan() {
    local -a targets=("$@")
    local scan_type count
    local -a port_args=()

    header "Active scan"
    info "Targets: ${targets[*]}"

    ensure_nmap || return 1

    # SYN scan needs root. Otherwise use a TCP connect scan.
    if [[ $EUID -eq 0 ]]; then
        scan_type="-sS"
    else
        scan_type="-sT"
        warn "Not root: using a TCP connect scan (-sT)"
    fi

    live_file=$(mktemp) || { fail "could not create a temporary file"; return 1; }

    # Stage 1: host discovery. -n skips reverse DNS. -oG - gives parseable output.
    if ! nmap -sn -n -oG - "${targets[@]}" | awk '/Status: Up/ {print $2}' > "$live_file"; then
        fail "host discovery failed"
        return 1
    fi

    count=$(grep -c . "$live_file" || true)
    if (( count == 0 )); then
        info "No live hosts found"
        return 0
    fi
    info "$count live host(s) found"

    # Stage 2: service and version detection on live hosts only.
    # -Pn: stage 1 already confirmed these hosts are up.
    if [[ -n "$PORTS" ]]; then
        port_args=(-p "$PORTS")
    fi

    if ! nmap "$scan_type" -sV -Pn -n -T3 "${port_args[@]+"${port_args[@]}"}" -iL "$live_file"; then
        fail "service scan exited with an error"
        return 1
    fi
    return 0
}

# ---- Argument parsing ------------------------------------------------------

while getopts ":a:p:lh" opt; do
    case "$opt" in
        a) TARGETS+=("$OPTARG") ;;
        p) PORTS="$OPTARG" ;;
        l) USE_LOCAL=1 ;;
        h) usage; exit 0 ;;
        :) fail "option -$OPTARG needs an argument"; usage; exit 2 ;;
        *) fail "unknown option: -$OPTARG"; usage; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

if (( $# > 0 )); then
    fail "unexpected argument: $1"
    usage
    exit 2
fi

# ---- Build and validate the scan scope (before any output or scanning) -----

if (( USE_LOCAL )); then
    if local_cidr=$(detect_local_subnet); then
        info "Detected local subnet: $local_cidr"
        TARGETS+=("$local_cidr")
    else
        fail "could not detect the local subnet from the default route (use -a instead)"
        exit 2
    fi
fi

for t in "${TARGETS[@]+"${TARGETS[@]}"}"; do
    valid_target "$t" || {
        fail "invalid target '$t': use an IPv4 address, range (10.0.0.5-20), CIDR /16 to /32, or hostname"
        exit 2
    }
done

if [[ -n "$PORTS" ]] && ! valid_ports "$PORTS"; then
    fail "invalid port list '$PORTS' (examples: 22,80,443 or 1-1024)"
    exit 2
fi

if (( ${#TARGETS[@]} == 0 )) && [[ -n "$PORTS" ]]; then
    warn "-p has no effect without a scan target (-a or -l)"
fi

# ---- Run -------------------------------------------------------------------

header "Network audit"
[[ $EUID -eq 0 ]] || warn "Not running as root: process names for sockets are limited and SYN scanning is unavailable"
echo

check_listening;   echo
check_connections; echo
check_interfaces;  echo
check_routes;      echo
check_arp

if (( ${#TARGETS[@]} > 0 )); then
    echo
    run_active_scan "${TARGETS[@]}" || exit 1
fi

exit 0