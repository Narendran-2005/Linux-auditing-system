#!/bin/bash
# setup-deps.sh - checks dependencies, asks for permission, then installs
# Usage: ./setup-deps.sh [-c] [-y]
#   -c  check only, change nothing
#   -y  install without asking (sudo is still required)
#   -h  help
set -u -o pipefail

CHECK_ONLY=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: ./setup-deps.sh [-c] [-y]
  -c   check only: report what is missing, change nothing
  -y   install without asking
  -h   show this help
EOF
}

while getopts ":cyh" opt; do
    case "$opt" in
        c) CHECK_ONLY=1 ;;
        y) ASSUME_YES=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

YELLOW=$'\e[1;33m'; GREEN=$'\e[1;32m'; RED=$'\e[1;31m'; NORMAL=$'\e[0m'
[[ -t 1 ]] || { YELLOW=""; GREEN=""; RED=""; NORMAL=""; }

ok()   { echo -e "${GREEN}[OK]${NORMAL}      $*"; }
miss() { echo -e "${RED}[MISSING]${NORMAL} $*"; }
note() { echo -e "${YELLOW}[NOTE]${NORMAL}    $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- Requirements ----------------------------------------------------------
# Format: tool|level|purpose
#   required: the project cannot run without it
#   optional: one check is skipped without it
# systemctl is listed but cannot be installed: it comes with systemd.

REQUIREMENTS=(
    "python3|required|dashboard (master.sh -d)"
    "ss|required|sockets and connections (network.sh, ssh.sh)"
    "ip|required|interfaces, routes, ARP (network.sh)"
    "sysctl|required|kernel hardening checks (kernel.sh)"
    "ps|required|process checks (process.sh)"
    "findmnt|required|mount point checks (File_system.sh)"
    "ssh-keygen|required|SSH key fingerprints (ssh.sh)"
    "systemctl|required|service checks (service.sh, ssh.sh) - part of systemd"
    "free|optional|memory summary (memory.sh)"
    "lscpu|optional|CPU details (hardware.sh)"
    "lsblk|optional|block devices (hardware.sh)"
    "lsusb|optional|USB devices (hardware.sh)"
    "dmidecode|optional|system manufacturer (hardware.sh, needs root)"
    "top|optional|CPU snapshot (systemd.sh)"
    "mpstat|optional|per-core CPU statistics (systemd.sh)"
    "nmap|optional|active scans (network.sh -a / -l)"
    "figlet|optional|banner text (design.sh)"
    "ufw|optional|firewall status (ssh.sh)"
)

# ---- Package manager -------------------------------------------------------

detect_pm() {
    if   have apt-get; then PM=apt
    elif have dnf;     then PM=dnf
    elif have yum;     then PM=yum
    elif have pacman;  then PM=pacman
    elif have zypper;  then PM=zypper
    elif have apk;     then PM=apk
    else PM=""
    fi
}

# Maps a command to its package name. Only exceptions are listed;
# everything else uses the command name as the package name.
pkg_for() {
    local tool="$1"
    case "$tool" in
        python3)
            [[ "$PM" == pacman ]] && { echo python; return; }
            echo python3 ;;
        ss|ip)                 echo iproute2 ;;
        lsusb)                 echo usbutils ;;
        findmnt|lscpu|lsblk)   echo util-linux ;;
        free|ps|sysctl)
            [[ "$PM" == pacman || "$PM" == apk ]] && { echo procps-ng; return; }
            echo procps ;;
        top)
            [[ "$PM" == pacman || "$PM" == apk ]] && { echo procps-ng; return; }
            echo procps ;;
        mpstat)                echo sysstat ;;
        ssh-keygen)
            [[ "$PM" == pacman || "$PM" == apk ]] && { echo openssh; return; }
            echo openssh-client ;;
        systemctl)             echo "" ;;   # not installable separately
        *)                     echo "$tool" ;;
    esac
}

# Adds $2 to the array named $1 only if it is not already there
add_unique() {
    local -n _arr="$1"
    local item
    for item in "${_arr[@]+"${_arr[@]}"}"; do
        [[ "$item" == "$2" ]] && return 0
    done
    _arr+=("$2")
}

# ---- Phase 1: check --------------------------------------------------------
# All results live in these arrays. They are reset at the start of every check,
# so a re-check after installing reports only the current state.

MISSING_REQ=()      # tools
MISSING_OPT=()      # tools
PKGS_REQ=()         # packages that fix the required tools
PKGS_OPT=()         # packages that fix the optional tools
UNINSTALLABLE=()    # missing tools with no package to install

check_tools() {
    MISSING_REQ=(); MISSING_OPT=(); PKGS_REQ=(); PKGS_OPT=(); UNINSTALLABLE=()

    local entry tool level purpose pkg
    for entry in "${REQUIREMENTS[@]}"; do
        IFS='|' read -r tool level purpose <<< "$entry"
        if have "$tool"; then
            ok "$tool  ($purpose)"
            continue
        fi

        miss "$tool  ($purpose)"
        pkg=$(pkg_for "$tool")

        if [[ "$level" == required ]]; then
            MISSING_REQ+=("$tool")
            if [[ -n "$pkg" ]]; then add_unique PKGS_REQ "$pkg"; else UNINSTALLABLE+=("$tool"); fi
        else
            MISSING_OPT+=("$tool")
            if [[ -n "$pkg" ]]; then add_unique PKGS_OPT "$pkg"; else UNINSTALLABLE+=("$tool"); fi
        fi
    done
}

# ---- Phase 3: install ------------------------------------------------------

SUDO=()
if (( EUID != 0 )); then
    have sudo || { miss "not root and sudo is not installed: run as root"; exit 1; }
    SUDO=(sudo)
fi

refresh_index() {
    case "$PM" in
        apt)    "${SUDO[@]+"${SUDO[@]}"}" apt-get update ;;
        pacman) "${SUDO[@]+"${SUDO[@]}"}" pacman -Sy --noconfirm ;;
        apk)    "${SUDO[@]+"${SUDO[@]}"}" apk update ;;
        zypper) "${SUDO[@]+"${SUDO[@]}"}" zypper --non-interactive refresh ;;
    esac
}

install_packages() {
    local -a cmd
    case "$PM" in
        apt)    cmd=(apt-get install -y) ;;
        dnf)    cmd=(dnf install -y) ;;
        yum)    cmd=(yum install -y) ;;
        pacman) cmd=(pacman -S --needed --noconfirm) ;;
        zypper) cmd=(zypper --non-interactive install) ;;
        apk)    cmd=(apk add) ;;
    esac
    "${SUDO[@]+"${SUDO[@]}"}" "${cmd[@]}" "$@"
}

# ---- Main flow -------------------------------------------------------------

echo "Linux Auditing: dependency setup"
echo

detect_pm
if [[ -n "$PM" ]]; then
    note "package manager: $PM"
else
    note "no supported package manager found (apt, dnf, yum, pacman, zypper, apk)"
fi
echo

# Phase 1: check availability
echo "Checking availability..."
echo
check_tools
echo

if (( ${#MISSING_REQ[@]} == 0 && ${#MISSING_OPT[@]} == 0 )); then
    ok "all dependencies are installed"
    exit 0
fi

(( ${#MISSING_REQ[@]} > 0 )) && miss "required: ${MISSING_REQ[*]}"
(( ${#MISSING_OPT[@]} > 0 )) && note "optional: ${MISSING_OPT[*]}"
(( ${#UNINSTALLABLE[@]} > 0 )) && note "no package available for: ${UNINSTALLABLE[*]}"

if (( CHECK_ONLY )); then
    echo
    note "check-only mode: nothing was installed"
    exit 1
fi

if [[ -z "$PM" ]]; then
    echo
    miss "install these manually, then rerun: ${MISSING_REQ[*]} ${MISSING_OPT[*]}"
    exit 1
fi

# Phase 2: ask permission
echo
echo "Packages that would be installed:"
echo "  required: ${PKGS_REQ[*]:-none}"
echo "  optional: ${PKGS_OPT[*]:-none}"
echo

choice=""
if (( ASSUME_YES )); then
    choice="a"
elif [[ -t 0 ]]; then
    read -r -p "Install [a]ll, [r]equired only, or [n]othing? [n] " answer
    case "${answer,,}" in
        a|all)       choice="a" ;;
        r|required)  choice="r" ;;
        *)           choice="n" ;;
    esac
else
    note "no terminal to ask on: rerun with -y to install without prompting"
    exit 1
fi

case "$choice" in
    a) to_install=("${PKGS_REQ[@]+"${PKGS_REQ[@]}"}" "${PKGS_OPT[@]+"${PKGS_OPT[@]}"}") ;;
    r) to_install=("${PKGS_REQ[@]+"${PKGS_REQ[@]}"}") ;;
    *) note "installation cancelled, nothing changed"; exit 1 ;;
esac

if (( ${#to_install[@]} == 0 )); then
    note "no installable packages selected"
    exit 1
fi

# Phase 3: install
echo
echo "Installing: ${to_install[*]}"
if ! refresh_index; then
    miss "could not refresh the package index (check the network)"
    exit 1
fi
if ! install_packages "${to_install[@]}"; then
    miss "package installation failed"
    exit 1
fi

# Verify: a fresh check, so the result reflects the system now
echo
echo "Verifying..."
echo
check_tools
echo

if (( ${#MISSING_REQ[@]} > 0 )); then
    miss "required tools still missing: ${MISSING_REQ[*]}"
    exit 1
fi

ok "setup complete"
(( ${#MISSING_OPT[@]} > 0 )) && note "optional tools still missing: ${MISSING_OPT[*]}"
exit 0