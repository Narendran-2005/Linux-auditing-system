#!/bin/bash
# User_account.sh - user account review
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

header "Human user accounts (UID 1000-65533)"
while IFS=: read -r user _ uid _ _ home shell; do
    if (( uid >= 1000 && uid < 65534 )); then
        info "$user  uid=$uid  home=$home  shell=$shell"
    fi
done < /etc/passwd

echo
header "Accounts with UID 0"
uid0=$(awk -F: '$3 == 0 {print $1}' /etc/passwd)
for u in $uid0; do
    if [[ "$u" == "root" ]]; then
        info "root (expected)"
    else
        fail "$u has UID 0 (root privileges)"
    fi
done

echo
header "Accounts with a login shell"
awk -F: '$7 !~ /(nologin|false)$/ {printf "       %s (%s)\n", $1, $7}' /etc/passwd

echo
header "Accounts with empty passwords"
if [[ $EUID -eq 0 ]]; then
    empty=$(awk -F: '$2 == "" {print $1}' /etc/shadow)
    if [[ -z "$empty" ]]; then
        pass "No accounts have empty passwords"
    else
        fail "Accounts with empty passwords: $(paste -sd' ' - <<< "$empty")"
    fi
else
    warn "Run as root to check /etc/shadow for empty passwords"
fi

echo
header "Privileged group members"
for g in sudo wheel admin; do
    members=$(getent group "$g" | cut -d: -f4)
    [[ -n "$members" ]] && info "$g: $members"
done

echo
header "Password maximum age"
max_days=$(awk '/^PASS_MAX_DAYS/ {print $2}' /etc/login.defs 2>/dev/null)
if [[ -z "$max_days" ]]; then
    warn "PASS_MAX_DAYS not set in /etc/login.defs"
elif (( max_days <= 90 )); then
    pass "PASS_MAX_DAYS is $max_days"
else
    fail "PASS_MAX_DAYS is $max_days (recommended: 90 or less)"
fi