#Validates that the host is ready to deploy the lab.
# Run this before vm/deploy.sh
#

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"

PASSED=0; WARNED=0; FAILED=0

ok()   { log_ok   "$*"; (( PASSED++ )); }
warn() { log_warn "$*"; (( WARNED++ )); }
fail() { log_warn "$*"; (( FAILED++ )); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT_FILE="$(realpath "${SCRIPT_DIR}/../vm/cloud-init.yaml")"

echo ""
echo "  k8s-sre-lab — Host Validation"
echo "  $(uname -n)  |  kernel $(uname -r)  |  $(date '+%Y-%m-%d %H:%M')"

# --- KVM -------------------------------------------------------------------
log_step "KVM"

[[ -e /dev/kvm ]]                             && ok "/dev/kvm exists"     || fail "/dev/kvm not found — enable VT-x/AMD-V in BIOS"
grep -qE 'vmx|svm' /proc/cpuinfo             && ok "Virtualization CPU flags present" || fail "vmx/svm flags missing from /proc/cpuinfo"
groups | grep -qE '\bkvm\b|\blibvirt\b'      && ok "User is in kvm/libvirt group" \
                                             || warn "User not in kvm/libvirt — fix: sudo usermod -aG kvm,libvirt \$USER && newgrp libvirt"

# --- Packages --------------------------------------------------------------
log_step "Required packages"

for cmd in qemu-img virt-install virsh wget ssh; do
    command -v "${cmd}" &>/dev/null && ok "${cmd}" || { fail "${cmd} not found"; warn "  fix: sudo pacman -S qemu-full libvirt virt-install"; }
done

OVMF_FOUND=false
for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    [[ -f "$p" ]] && { ok "OVMF firmware: $p"; OVMF_FOUND=true; break; }
done
${OVMF_FOUND} || { fail "OVMF firmware not found"; warn "  fix: sudo pacman -S edk2-ovmf"; }

# --- libvirtd --------------------------------------------------------------
log_step "libvirtd"

systemctl is-active --quiet libvirtd  && ok "libvirtd running"  || { fail "libvirtd not running";  warn "  fix: sudo systemctl start libvirtd"; }
systemctl is-enabled --quiet libvirtd && ok "libvirtd enabled"  || warn "libvirtd not enabled — fix: sudo systemctl enable libvirtd"

# --- Network bridge --------------------------------------------------------
log_step "Network bridge (br0)"

if ip link show br0 &>/dev/null; then
    STATE=$(ip link show br0 | awk '/state/{print $9}')
    ok "br0 exists (state: ${STATE})"
    [[ "${STATE}" == "UP" ]] && ok "br0 is UP" || fail "br0 is not UP — fix: sudo ip link set br0 up"
    ip addr show br0 2>/dev/null | grep -q "inet " \
        && ok "br0 has IP: $(ip addr show br0 | awk '/inet /{print $2}' | head -1)" \
        || warn "br0 has no IP — check DHCP or set a static address"
else
    fail "br0 not found"
    warn "  fix:"
    warn "    nmcli con add type bridge ifname br0 con-name br0"
    warn "    nmcli con add type bridge-slave ifname <nic> master br0"
    warn "    nmcli con modify br0 bridge.stp no && nmcli con up br0"
fi

# --- Disk space ------------------------------------------------------------
log_step "Disk space (/var/lib/libvirt/images)"

IMAGES_DIR="/var/lib/libvirt/images"
if [[ -d "${IMAGES_DIR}" ]]; then
    ok "${IMAGES_DIR} exists"
    AVAIL=$(df -BG "${IMAGES_DIR}" | awk 'NR==2{print $4}' | tr -d 'G')
    (( AVAIL >= 100 )) && ok "${AVAIL} GB available" \
        || (( AVAIL >= 80 )) && warn "${AVAIL} GB available (100+ recommended)" \
        || fail "Only ${AVAIL} GB available — need at least 80 GB"

    DEV=$(df "${IMAGES_DIR}" | awk 'NR==2{print $1}' | sed 's/[0-9]*$//;s/p[0-9]*$//')
    ROT=$(cat "/sys/block/$(basename "${DEV}")/queue/rotational" 2>/dev/null || echo "?")
    [[ "${ROT}" == "0" ]] && ok "Storage: SSD/NVMe" || warn "Storage may be HDD — k3s + Prometheus need low-latency disk"
else
    fail "${IMAGES_DIR} does not exist — fix: sudo mkdir -p ${IMAGES_DIR}"
fi

# --- SSH key ---------------------------------------------------------------
log_step "SSH key"

SSH_FOUND=false
for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    [[ -f "$f" ]] && { ok "SSH public key: $f"; SSH_FOUND=true; break; }
done
${SSH_FOUND} || { fail "No SSH public key found"; warn "  fix: ssh-keygen -t ed25519 -C 'you@example.com'"; }

# --- cloud-init ------------------------------------------------------------
log_step "vm/cloud-init.yaml"

[[ -f "${CLOUD_INIT_FILE}" ]] && ok "cloud-init.yaml found" || fail "cloud-init.yaml not found: ${CLOUD_INIT_FILE}"

grep -q "REPLACE_WITH_YOUR_PUBLIC_KEY"    "${CLOUD_INIT_FILE}" 2>/dev/null \
    && fail "SSH key placeholder not replaced" \
    || ok   "SSH key is set"

grep -q "REPLACE_WITH_HASHED_PASSWORD"    "${CLOUD_INIT_FILE}" 2>/dev/null \
    && fail "Password placeholder not replaced — run: openssl passwd -6" \
    || ok   "Password is set"

command -v python3 &>/dev/null && {
    python3 -c "import yaml; yaml.safe_load(open('${CLOUD_INIT_FILE}'))" 2>/dev/null \
        && ok "YAML syntax valid" \
        || fail "YAML syntax error in cloud-init.yaml"
}

# --- Host resources --------------------------------------------------------
log_step "Host resources"

RAM=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPUS=$(nproc)

(( RAM >= 16384 )) && ok "RAM: ${RAM} MB" \
    || (( RAM >= 12288 )) && warn "RAM: ${RAM} MB — consider reducing VM_RAM_MB in vm/deploy.sh" \
    || fail "RAM: ${RAM} MB — may be insufficient for an 8 GB VM"

(( CPUS >= 8 )) && ok "CPUs: ${CPUS}" \
    || (( CPUS >= 4 )) && warn "CPUs: ${CPUS} — consider reducing VM_VCPUS in vm/deploy.sh" \
    || fail "CPUs: ${CPUS} — minimum 4 physical cores recommended"

# --- Summary ---------------------------------------------------------------
echo ""
echo "  -----------------------------------------------"
printf  "  Passed: %s   Warnings: %s   Failed: %s\n" "${PASSED}" "${WARNED}" "${FAILED}"
echo "  -----------------------------------------------"
echo ""

(( FAILED > 0 ))  && { log_warn "Fix FAIL items before running vm/deploy.sh"; exit 1; }
(( WARNED > 0 ))  && { log_warn "Review warnings, then run: bash vm/deploy.sh"; exit 0; }
log_ok "All checks passed — run: bash vm/deploy.sh"
echo ""
