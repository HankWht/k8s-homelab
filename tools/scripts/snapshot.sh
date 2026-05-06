# VM snapshot manager. Snapshot before any major change, revert is instant.
#
# Usage:
#   bash scripts/snapshot.sh create  <label>
#   bash scripts/snapshot.sh list
#   bash scripts/snapshot.sh revert  <snapshot-name>
#   bash scripts/snapshot.sh delete  <snapshot-name>

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"

VM="k8s-lab"
ACTION="${1:-list}"
LABEL="${2:-}"

case "${ACTION}" in

create)
    [[ -z "${LABEL}" ]] && log_error "Provide a label. Example: bash scripts/snapshot.sh create before monitoring"
    NAME="${LABEL}-$(date +%Y%m%d-%H%M)"
    virsh snapshot-create-as "${VM}" "${NAME}" --description "Created $(date)"
    log_ok "Snapshot created: ${NAME}"
    echo "  Revert with: bash scripts/snapshot.sh revert ${NAME}"
    ;;

list)
    virsh snapshot-list "${VM}" --tree 2>/dev/null || virsh snapshot-list "${VM}"
    ;;

revert)
    [[ -z "${LABEL}" ]] && log_error "Provide a snapshot name. Run 'list' to see names."
    log_warn "This will undo all changes made after '${LABEL}'."
    read -rp "  Continue? [y/N] " CHOICE
    [[ "${CHOICE}" =~ ^[Yy]$ ]] || { log_info "Cancelled"; exit 0; }
    virsh snapshot-revert "${VM}" "${LABEL}"
    virsh start "${VM}" 2>/dev/null && log_ok "VM started" || log_warn "VM may already be running"
    ;;

delete)
    [[ -z "${LABEL}" ]] && log_error "Provide a snapshot name. Run 'list' to see names."
    read -rp "  Permanently delete '${LABEL}'? [y/N] " CHOICE
    [[ "${CHOICE}" =~ ^[Yy]$ ]] || { log_info "Cancelled"; exit 0; }
    virsh snapshot-delete "${VM}" "${LABEL}"
    log_ok "Deleted: ${LABEL}"
    ;;

*)
    echo "Usage: bash scripts/snapshot.sh <create|list|revert|delete> [name]"
    log_error "Unknown action: '${ACTION}'"
    ;;
esac
