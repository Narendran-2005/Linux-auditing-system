#!/bin/bash
# lib.sh - shared helpers. Sourced by the other scripts, not run directly.

if [[ -t 1 ]]; then
    YELLOW=$'\e[1;33m'
    GREEN=$'\e[1;32m'
    RED=$'\e[1;31m'
    NORMAL=$'\e[0m'
else
    YELLOW=""; GREEN=""; RED=""; NORMAL=""
fi

header() { echo -e "${YELLOW}$*${NORMAL}"; }
pass()   { echo -e "${GREEN}[PASS]${NORMAL} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NORMAL} $*"; }
fail()   { echo -e "${RED}[FAIL]${NORMAL} $*"; }
info()   { echo "       $*"; }
have()   { command -v "$1" >/dev/null 2>&1; }