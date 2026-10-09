#!/bin/bash
# hardware.sh - hardware overview
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail

header "System information"
if have dmidecode && [[ $EUID -eq 0 ]]; then
    dmidecode -t 1 2>/dev/null | grep -E '^\s+(Manufacturer|Product Name):' \
        || warn "dmidecode returned no system information"
else
    warn "dmidecode needs root and must be installed - skipping"
fi

echo
header "CPU information"
if have lscpu; then
    lscpu | grep -E '^(Architecture|Model name|Vendor ID|CPU\(s\)|Virtualization|Stepping|L3 cache|Vulnerability)'
else
    warn "lscpu not installed (package: util-linux)"
fi

echo
header "USB information"
if have lsusb; then
    lsusb
else
    warn "lsusb not installed (package: usbutils)"
fi

echo
header "Block devices"
if have lsblk; then
    lsblk
else
    warn "lsblk not installed (package: util-linux)"
fi