#!/usr/bin/env bash
# Shared logging functions.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"

COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET}  $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET}  $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_error() { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET}  $*" >&2; exit 1; }
log_step()  {
    echo ""
    echo -e "${COLOR_BLUE}-- $* ${COLOR_RESET}"
}
