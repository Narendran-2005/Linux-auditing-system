#!/bin/bash
# master.sh - dispatcher for the Linux auditing scripts
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
set -u -o pipefail

ALL_CHECKS=(
    User_account.sh
    memory.sh
    File_permission.sh
    File_system.sh
    hardware.sh
    process.sh
    service.sh
    kernel.sh
    systemd.sh
    ssh.sh
    software.sh
)

show_help() {
    cat <<'EOF'
Usage: master.sh [options]

  -A, --all            Run every host audit (not network)
  -U, --user           User accounts
  -M, --memory         Memory information
  -F, --file-perm      File permissions of sensitive files
  -S, --file-system    File system mount points and options
  -H, --hardware       Hardware information
  -P, --process        Zombie and I/O-blocked processes
  -s, --service        Running and risky services
  -K, --kernel         Kernel hardening parameters
  -SS, --software      Installed packages
  -Sm, --systemd       System performance (CPU, disk, load)
  -n, --ssh            SSH configuration
  -N, --network        Passive network checks (active scans: run network.sh -a)
  -d, --dashboard      Build an HTML dashboard in ./reports
      --skip-setup     Do not check or install dependencies before the audit
  -h, --help           Show this help message
EOF
}

if [[ $# -eq 0 ]]; then
    show_help
    exit 1
fi

selected=()
want_dashboard=0
skip_setup=0
results_file=""

cleanup() {
    [[ -n "$results_file" ]] && rm -f "$results_file"
    return 0
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        -A|--all)          selected+=("${ALL_CHECKS[@]}") ;;
        -U|--user)         selected+=(User_account.sh) ;;
        -M|--memory)       selected+=(memory.sh) ;;
        -F|--file-perm)    selected+=(File_permission.sh) ;;
        -S|--file-system)  selected+=(File_system.sh) ;;
        -H|--hardware)     selected+=(hardware.sh) ;;
        -P|--process)      selected+=(process.sh) ;;
        -s|--service)      selected+=(service.sh) ;;
        -K|--kernel)       selected+=(kernel.sh) ;;
        -SS|--software)    selected+=(software.sh) ;;
        -Sm|--systemd)     selected+=(systemd.sh) ;;
        -n|--ssh)          selected+=(ssh.sh) ;;
        -N|--network)      selected+=(network.sh) ;;
        -d|--dashboard)    want_dashboard=1 ;;
        --skip-setup)      skip_setup=1 ;;
        -h|--help)         show_help; exit 0 ;;
        *)                 echo "Unknown option: $1" >&2; show_help; exit 1 ;;
    esac
    shift
done

if (( ${#selected[@]} == 0 )); then
    echo "Nothing to run: choose at least one audit option." >&2
    exit 2
fi

# Remove duplicates while keeping order
declare -A seen
unique=()
for s in "${selected[@]}"; do
    if [[ -z "${seen[$s]:-}" ]]; then
        seen[$s]=1
        unique+=("$s")
    fi
done

[[ $EUID -eq 0 ]] || warn "Not running as root: some checks will be limited"

# Dependency check: runs before any audit, so the user is asked once per run.
# setup-deps.sh checks, asks for permission, then installs. Its exit status is
# not treated as fatal: declining or failing an install just means some checks
# are skipped, and the audit continues.
if (( ! skip_setup )); then
    if [[ -f "$DIR/setup-deps.sh" ]]; then
        echo
        bash "$DIR/setup-deps.sh" || warn "Some dependencies are missing: related checks will be skipped"
        echo
    else
        warn "setup-deps.sh not found in $DIR: dependency check skipped"
    fi
fi

# Results are recorded only after the setup step, so it is not counted as a finding
if (( want_dashboard )); then
    results_file=$(mktemp) || { fail "cannot create a temporary results file"; exit 1; }
    export AUDIT_RESULTS="$results_file"
fi

bash "$DIR/design.sh"
for s in "${unique[@]}"; do
    echo
    if [[ -f "$DIR/$s" ]]; then
        bash "$DIR/$s"
    else
        fail "$s not found in $DIR"
    fi
done

if (( want_dashboard )); then
    echo
    bash "$DIR/dashboard.sh" "$results_file"
fi

exit 0