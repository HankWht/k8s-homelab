# Configures wildcard *.lab DNS on the host via NetworkManager's dnsmasq plugin.
# After this, http://grafana.lab and similar hostnames resolve in your browser.
#
# Usage: bash scripts/setup-dns.sh <metallb-ip>
# When:  After MetalLB is deployed. Get the IP with:
#          kubectl -n ingress-nginx get svc ingress-nginx-controller

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"

METALLB_IP="${1:-}"

[[ -z "${METALLB_IP}" ]] && {
    echo "Usage: bash scripts/setup-dns.sh <metallb-ip>"
    log_error "No IP address provided"
}

echo "${METALLB_IP}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    || log_error "Invalid IP format: '${METALLB_IP}'"

log_info "Configuring *.lab -> ${METALLB_IP}"

# Enable dnsmasq in NetworkManager
log_step "NetworkManager"

NM_CONF="/etc/NetworkManager/NetworkManager.conf"

if grep -q "^dns=dnsmasq" "${NM_CONF}"; then
    log_ok "dnsmasq already enabled"
elif grep -q "^dns=" "${NM_CONF}"; then
    sudo sed -i 's/^dns=.*/dns=dnsmasq/' "${NM_CONF}"
    log_ok "Replaced existing dns= with dns=dnsmasq"
elif grep -q "^\[main\]" "${NM_CONF}"; then
    sudo sed -i '/^\[main\]/a dns=dnsmasq' "${NM_CONF}"
    log_ok "Added dns=dnsmasq under [main]"
else
    printf '\n[main]\ndns=dnsmasq\n' | sudo tee -a "${NM_CONF}" > /dev/null
    log_ok "Added [main] section with dns=dnsmasq"
fi

# Write the wildcard rule
log_step "DNS rule"

DNSMASQ_DIR="/etc/NetworkManager/dnsmasq.d"
sudo mkdir -p "${DNSMASQ_DIR}"
echo "address=/.lab/${METALLB_IP}" | sudo tee "${DNSMASQ_DIR}/k8s-sre-lab.conf" > /dev/null
log_ok "Rule written: *.lab -> ${METALLB_IP}"

# Apply
log_step "Applying"

sudo systemctl restart NetworkManager
sleep 3
log_ok "NetworkManager restarted"

# Verify
RESOLVED=""
command -v dig &>/dev/null      && RESOLVED=$(dig +short +timeout=3 grafana.lab 2>/dev/null | tail -1)
command -v nslookup &>/dev/null && [[ -z "${RESOLVED}" ]] \
    && RESOLVED=$(nslookup grafana.lab 2>/dev/null | awk '/^Address/ && !/127\.0\.0\.1/{print $2}' | head -1)

[[ "${RESOLVED}" == "${METALLB_IP}" ]] \
    && log_ok "DNS verified: grafana.lab -> ${METALLB_IP}" \
    || { log_warn "Verification inconclusive (got: '${RESOLVED:-empty}')"; log_warn "Test with: dig grafana.lab"; }

echo ""
echo "  Apply Ingress rules to expose services:"
echo "    kubectl apply -f kubernetes/monitoring/grafana-ingress.yaml"
echo "    kubectl apply -f kubernetes/monitoring/prometheus-ingress.yaml"
echo ""
