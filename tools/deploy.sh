# Deploys the k8s-sre-lab VM using the Ubuntu 26.04 cloud image.
# Run scripts/validate.sh first to confirm the host is ready.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/log.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

VM_NAME="k8s-lab"
VM_RAM_MB=8192
VM_VCPUS=4
VM_DISK_SIZE="80G"
VM_BRIDGE="br0"
VM_DISK="/var/lib/libvirt/images/k8s-lab.qcow2"

CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
CLOUD_IMAGE_CACHE="/var/lib/libvirt/images/ubuntu-26.04-cloudimg.img"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT="$(realpath "${SCRIPT_DIR}/cloud-init.yaml")"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

log_step "Pre-flight"

systemctl is-active --quiet libvirtd      || log_error "libvirtd not running — sudo systemctl start libvirtd"
ip link show "${VM_BRIDGE}" &>/dev/null   || log_error "Bridge '${VM_BRIDGE}' not found — see README step 2"
log_ok "libvirtd running, bridge ${VM_BRIDGE} exists"

OVMF=""
for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    [[ -f "$p" ]] && { OVMF="$p"; break; }
done
[[ -n "${OVMF}" ]] || log_error "UEFI firmware not found — sudo pacman -S edk2-ovmf"
log_ok "OVMF firmware: ${OVMF}"

[[ -f "${CLOUD_INIT}" ]]                                       || log_error "vm/cloud-init.yaml not found"
grep -q "REPLACE_WITH_YOUR_PUBLIC_KEY" "${CLOUD_INIT}"         && log_error "SSH key not set in vm/cloud-init.yaml"
grep -q "REPLACE_WITH_HASHED_PASSWORD" "${CLOUD_INIT}"         && log_error "Password not set in vm/cloud-init.yaml"
log_ok "cloud-init.yaml ready"

if virsh dominfo "${VM_NAME}" &>/dev/null; then
    log_warn "VM '${VM_NAME}' already exists."
    read -rp "  Destroy and recreate? [y/N] " CHOICE
    [[ "${CHOICE}" =~ ^[Yy]$ ]] || { log_info "Aborted"; exit 0; }
    virsh destroy "${VM_NAME}" 2>/dev/null || true
    virsh undefine "${VM_NAME}" --remove-all-storage 2>/dev/null || true
    log_ok "Existing VM removed"
fi

# ---------------------------------------------------------------------------
# Cloud image
# ---------------------------------------------------------------------------

log_step "Ubuntu 26.04 cloud image"

if [[ -f "${CLOUD_IMAGE_CACHE}" ]]; then
    log_ok "Cached: ${CLOUD_IMAGE_CACHE}"
else
    log_info "Downloading (~600 MB, cached for future use)..."
    wget --progress=bar:force -O "${CLOUD_IMAGE_CACHE}" "${CLOUD_IMAGE_URL}"
    log_ok "Download complete"
fi

# ---------------------------------------------------------------------------
# Disk
# ---------------------------------------------------------------------------

log_step "VM disk"

# Convert preserves the base image for reuse; preallocation=metadata avoids
# write latency spikes that occur with fully sparse qcow2 under heavy I/O
qemu-img convert -f qcow2 -O qcow2 -o preallocation=metadata \
    "${CLOUD_IMAGE_CACHE}" "${VM_DISK}"
qemu-img resize "${VM_DISK}" "${VM_DISK_SIZE}"
log_ok "Disk ready: ${VM_DISK} (${VM_DISK_SIZE})"

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

log_step "Creating VM"

virt-install \
    --name          "${VM_NAME}" \
    --ram           "${VM_RAM_MB}" \
    --vcpus         "${VM_VCPUS}",maxvcpus=8 \
    --cpu           host-passthrough \
    --os-variant    ubuntu24.04 \
    --machine       q35 \
    --import \
    --disk          "path=${VM_DISK},bus=scsi,driver.cache=none,driver.io=native,driver.discard=unmap" \
    --controller    type=scsi,model=virtio-scsi \
    --network       "bridge=${VM_BRIDGE},model=virtio,driver.queues=4" \
    --memballoon    model=virtio \
    --graphics      none \
    --console       pty,target_type=serial \
    --cloud-init    "user-data=${CLOUD_INIT}" \
    --boot          uefi \
    --noautoconsole

log_ok "VM created — cloud-init is provisioning"

# ---------------------------------------------------------------------------
# Wait for IP
# ---------------------------------------------------------------------------

log_step "Waiting for network"

VM_IP=""
for _ in $(seq 1 18); do
    VM_IP=$(virsh domifaddr "${VM_NAME}" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
    [[ -n "${VM_IP}" ]] && { log_ok "VM IP: ${VM_IP}"; break; }
    echo -n "."; sleep 10
done
echo ""

[[ -z "${VM_IP}" ]] && { log_warn "IP not detected — run: virsh domifaddr ${VM_NAME}"; VM_IP="<vm-ip>"; }

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------

echo ""
echo "  Watch provisioning:  virsh console ${VM_NAME}   (Ctrl+] to detach)"
echo ""
echo "  Poll until ready:"
echo "    watch -n15 'ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no \\"
echo "      labuser@${VM_IP} kubectl get nodes 2>/dev/null'"
echo ""
echo "  Copy kubeconfig to host:"
echo "    scp labuser@${VM_IP}:/home/labuser/.kube/config ~/.kube/k8s-lab.yaml"
echo "    sed -i 's/127.0.0.1/${VM_IP}/' ~/.kube/k8s-lab.yaml"
echo "    export KUBECONFIG=~/.kube/k8s-lab.yaml"
echo ""
