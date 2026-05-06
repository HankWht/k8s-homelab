# Serious Lab Only (No Bulto Allowed)

## Aquí no se viene a inventar… esto es serio, pana mio

---

## ⚙️ Overview
This lab is designed for real testing, real configs, and real consequences.
No shortcuts, no guesswork, **no bulto allowed**.

---

## Rules of Engagement
- Always snapshot before making changes
- Test before pushing anything to “prod-like”
- Document what you break (and hopefully fix)
- If it works… verify again 😄

---

## What’s Not Allowed
- Random configs without validation
- “Works on my machine” excuses
- Skipping backups
- Bulto. Ninguno.

---

## ✅ Goal
Build, break, fix, and learn the right way.

---

**Status:** Active 
**Mode:** No Bulto 

---

## Stack

| Component | Role |
| ---|---|
| Ubuntu 26.04 LTS | Guest OS, provisioned via cloud-init |
| k3s | Lightweight Kubernetes (single-node) |
| Prometheus + Alertmanager | Metrics collection and alerting |
| Grafana | Dashboards and visualization |
| Loki + Promtail | Log aggregation |
| NGINX Ingress | HTTP routing by hostname |
| MetalLB | LoadBalancer IP assignment (bare-metal) |

---

## Host requirements

- **OS:** CachyOS or any Arch-based Linux with KVM support (You can use whatever distro you want… but let’s be real, use Arch, mi pana :V 😄)
- **CPU:** 4+ cores, VT-x or AMD-V enabled in BIOS
- **RAM:** 16 GB (8 GB assigned to the VM, 8 GB for the host)
- **Disk:** 100 GB free on SSD/NVMe at `/var/lib/libvirt/images/`

---

## Directory structure

---

## Deployment

### 1. Install host dependencies

```bash
sudo pacman -S qemu-full libvirt virt-install edk2-ovmf bridge-utils
sudo systemctl enable --now libvirtd
sudo usermod -aG kvm,libvirt $USER && newgrp libvirt
```

### 2. Create a network bridge

The VM needs a bridged interface to get a real IP on your LAN.
Replace `enp3s0` with your actual NIC name (`ip link show` to find it).

```bash
nmcli con add type bridge ifname br0 con-name br0
nmcli con add type bridge-slave ifname enp3s0 master br0
nmcli con modify br0 bridge.stp no
nmcli con up br0
```

### 3. Configure cloud-init

Edit `vm/cloud-init.yaml` and replace the two placeholders

### 4. Validate and deploy

```bash
bash scripts/validate.sh      # fix any FAIL items first
bash vm/deploy.sh             # (image download + provisioning)
```

### 5. Access the cluster

```bash
VM_IP=$(virsh domifaddr k8s-lab | awk '/ipv4/{print $4}' | cut -d/ -f1)
mkdir -p ~/.kube
scp labuser@${VM_IP}:/home/labuser/.kube/config ~/.kube/k8s-lab.yaml
sed -i "s/127.0.0.1/${VM_IP}/" ~/.kube/k8s-lab.yaml
export KUBECONFIG=~/.kube/k8s-lab.yaml
kubectl get nodes
```

---

## Installing the monitoring stack

```bash
# SSH into the VM
ssh labuser@<vm-ip>

# Install NGINX Ingress Controller
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --values kubernetes/ingress/nginx-values.yaml

# Install MetalLB — edit the IP range first (see kubernetes/networking/metallb-pool.yaml)
helm install metallb metallb/metallb \
  --namespace metallb-system --create-namespace
kubectl -n metallb-system wait pod \
  --for=condition=Ready -l app.kubernetes.io/name=metallb --timeout=90s
kubectl apply -f kubernetes/networking/metallb-pool.yaml

# Get the IP MetalLB assigned, then configure DNS on your host
kubectl -n ingress-nginx get svc ingress-nginx-controller
bash scripts/setup-dns.sh 192.168.1.200   # replace with actual IP

# Install Prometheus, Grafana, and Alertmanager
kubectl create namespace monitoring
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values kubernetes/monitoring/stack-values.yaml

# Expose Grafana and Prometheus in the browser
kubectl apply -f kubernetes/monitoring/grafana-ingress.yaml
kubectl apply -f kubernetes/monitoring/prometheus-ingress.yaml
```

Open `http://grafana.lab` — login: `admin / bolecajuil123`
Open `http://prometheus.lab`

---

## Snapshots

Always snapshot before making changes you might want to undo… future you will either thank you, or file a ticket against past you 😄

```bash
bash scripts/snapshot.sh create  "before-monitoring"
bash scripts/snapshot.sh list
bash scripts/snapshot.sh revert  "before-monitoring-20260503-1430"
```

---
