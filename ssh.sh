#!/bin/bash
# ssh.sh - SSH service, effective configuration, keys, firewall and logs
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

header "SSH information"

# Service name: ssh (Debian/Ubuntu) or sshd (RHEL/Fedora/Arch)
if systemctl cat ssh >/dev/null 2>&1; then
    svc=ssh
elif systemctl cat sshd >/dev/null 2>&1; then
    svc=sshd
else
    svc=""
fi

if [[ -n "$svc" ]]; then
    info "Service ($svc): $(systemctl is-active "$svc")"
else
    warn "No ssh or sshd service found - SSH may not be installed"
fi

have ssh && info "$(ssh -V 2>&1)"

echo
header "Effective configuration"
SSHD=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
if [[ $EUID -eq 0 && -x "$SSHD" ]]; then
    SSHD_CFG=$("$SSHD" -T 2>/dev/null)
else
    warn "Not root or sshd missing: reading /etc/ssh/sshd_config (defaults and Include files not checked)"
    SSHD_CFG=$(awk 'NF && $1 !~ /^#/ {print tolower($1), $2}' /etc/ssh/sshd_config 2>/dev/null)
fi

# expect KEY "accepted values": compare the effective value with the accepted list
expect() {
    local key="$1" accepted="$2" got
    got=$(awk -v k="$key" '$1 == k {print $2; exit}' <<< "$SSHD_CFG")
    if [[ -z "$got" ]]; then
        warn "$key is not reported"
    elif [[ " $accepted " == *" $got "* ]]; then
        pass "$key $got"
    else
        fail "$key $got (accepted: $accepted)"
    fi
}

expect permitrootlogin          "no prohibit-password"
expect passwordauthentication   "no"
expect permitemptypasswords     "no"
expect x11forwarding            "no"
expect kbdinteractiveauthentication "no"
expect usepam                   "yes"

port=$(awk '$1 == "port" {print $2}' <<< "$SSHD_CFG" | paste -sd, -)
info "Port(s): ${port:-not set (default 22)}"

echo
header "Authorized keys (root and login users)"
while IFS=: read -r user _ uid _ _ home _; do
    (( uid == 0 || (uid >= 1000 && uid < 65534) )) || continue
    ak="$home/.ssh/authorized_keys"
    [[ -f "$ak" ]] || continue
    if [[ ! -r "$ak" ]]; then
        warn "Cannot read $ak (run as root)"
        continue
    fi
    info "$user ($ak):"
    ssh-keygen -lf "$ak" 2>/dev/null | sed 's/^/         /'
done < <(getent passwd)

echo
header "Firewall"
if have ufw; then
    ufw status 2>/dev/null || warn "ufw status needs root"
elif systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --state
elif have nft; then
    nft list ruleset 2>/dev/null | head -n 20
elif have iptables; then
    iptables -S 2>/dev/null | head -n 20
else
    warn "No firewall tool found (ufw, firewalld, nftables or iptables)"
fi

echo
header "Recent SSH log entries"
logfile=""
for f in /var/log/auth.log /var/log/secure; do
    if [[ -r "$f" ]]; then
        logfile="$f"
        break
    fi
done

if [[ -n "$logfile" ]]; then
    grep -i 'sshd' "$logfile" | tail -n 10
elif have journalctl && [[ -n "$svc" ]]; then
    journalctl -u "$svc" -n 10 --no-pager
else
    warn "No readable SSH log found"
fi

echo
echo "SSH audit completed - $(date)"