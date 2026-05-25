#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGISTRY_PORT=5000
BRIDGE_NAME="crudeagent-br"
BRIDGE_IP="192.168.100.1"
BRIDGE_SUBNET="192.168.100.0/24"
VM_IP="192.168.100.10"
TAP_NAME="crudeagent-tap"
# Detect the host's default outbound network interface (used for internet NAT)
HOST_IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"
AGENT_IMAGE="localhost:${REGISTRY_PORT}/crudeagent:latest"
SSH_DIR="${SCRIPT_DIR}/.ssh"

cleanup() {
    echo "=== Cleaning up network ==="
    sudo ip link set "${TAP_NAME}" down 2>/dev/null || true
    sudo ip link delete "${TAP_NAME}" 2>/dev/null || true
    sudo ip link set "${BRIDGE_NAME}" down 2>/dev/null || true
    sudo ip link delete "${BRIDGE_NAME}" 2>/dev/null || true
}

trap cleanup EXIT

echo "=== Step 1: Generate SSH keys for VM users ==="
mkdir -p "${SSH_DIR}"

if [ ! -f "${SSH_DIR}/service_ed25519" ]; then
    ssh-keygen -t ed25519 -f "${SSH_DIR}/service_ed25519" -N "" -C "service@crudeagent-vm"
    echo "Generated SSH key for 'service' user"
else
    echo "SSH key for 'service' already exists"
fi

SERVICE_PUBKEY=$(cat "${SSH_DIR}/service_ed25519.pub")

echo "=== Step 2: Build crudeagent Docker image ==="
docker build -f "${PROJECT_DIR}/crudeagent/native.Dockerfile" \
  -t crudeagent:latest \
  "${PROJECT_DIR}/crudeagent"

echo "=== Step 3: Start local Docker registry ==="
if docker ps --format '{{.Names}}' | grep -q '^registry$'; then
  echo "Registry already running"
else
  docker rm -f registry 2>/dev/null || true
  # Bind to 0.0.0.0 so the VM can reach it via the bridge IP (192.168.100.1:5000)
  docker run -d --name registry -p "0.0.0.0:${REGISTRY_PORT}:5000" registry:2
  echo "Registry started on port ${REGISTRY_PORT} (bound to 0.0.0.0)"
fi

echo "=== Step 4: Tag and push image to local registry ==="
docker tag crudeagent:latest "${AGENT_IMAGE}"
docker push "${AGENT_IMAGE}"

echo "=== Step 5: Convert Butane config to Ignition ==="
# Substitute SSH public key placeholder in the Butane config
sed \
  -e "s|SERVICE_SSH_PUBLIC_KEY_PLACEHOLDER|${SERVICE_PUBKEY}|g" \
  "${SCRIPT_DIR}/config.yaml" > "${SCRIPT_DIR}/config.yaml.rendered"

butane --strict "${SCRIPT_DIR}/config.yaml.rendered" > "${SCRIPT_DIR}/config.ign"
rm -f "${SCRIPT_DIR}/config.yaml.rendered"

echo "=== Step 6: Set up bridge and TAP networking ==="
# Create bridge
if ! ip link show "${BRIDGE_NAME}" &>/dev/null; then
  sudo ip link add "${BRIDGE_NAME}" type bridge
  sudo ip addr add "${BRIDGE_IP}/24" dev "${BRIDGE_NAME}"
  sudo ip link set "${BRIDGE_NAME}" up
  echo "Bridge ${BRIDGE_NAME} created at ${BRIDGE_IP}"
else
  echo "Bridge ${BRIDGE_NAME} already exists"
fi

# Create TAP device
if ! ip link show "${TAP_NAME}" &>/dev/null; then
  sudo ip tuntap add dev "${TAP_NAME}" mode tap user "$(whoami)"
  sudo ip link set "${TAP_NAME}" master "${BRIDGE_NAME}"
  sudo ip link set "${TAP_NAME}" up
  echo "TAP ${TAP_NAME} created and attached to ${BRIDGE_NAME}"
else
  echo "TAP ${TAP_NAME} already exists"
fi

# Enable IP forwarding and NAT so the VM can reach the internet and the host's Docker registry
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# NAT: masquerade all traffic from the VM subnet going out through the host's default interface
if [ -n "${HOST_IFACE}" ]; then
  if ! sudo iptables -t nat -C POSTROUTING -s "${BRIDGE_SUBNET}" -o "${HOST_IFACE}" -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -s "${BRIDGE_SUBNET}" -o "${HOST_IFACE}" -j MASQUERADE
    echo "NAT MASQUERADE added for ${BRIDGE_SUBNET} via ${HOST_IFACE}"
  fi
else
  echo "WARNING: Could not detect host default interface; internet access from VM may not work"
fi

# Also masquerade traffic going to the host itself (e.g. Docker registry on bridge IP)
if ! sudo iptables -t nat -C POSTROUTING -s "${BRIDGE_SUBNET}" ! -d "${BRIDGE_SUBNET}" -j MASQUERADE 2>/dev/null; then
  sudo iptables -t nat -A POSTROUTING -s "${BRIDGE_SUBNET}" ! -d "${BRIDGE_SUBNET}" -j MASQUERADE
fi

# Allow forwarding: bridge <-> external interface (internet access)
if [ -n "${HOST_IFACE}" ]; then
  sudo iptables -I FORWARD -i "${BRIDGE_NAME}" -o "${HOST_IFACE}" -j ACCEPT 2>/dev/null || true
  sudo iptables -I FORWARD -i "${HOST_IFACE}" -o "${BRIDGE_NAME}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi

# Allow forwarding on the bridge itself (needed if Docker sets FORWARD policy to DROP)
sudo iptables -I FORWARD -i "${BRIDGE_NAME}" -o "${BRIDGE_NAME}" -j ACCEPT 2>/dev/null || true
sudo iptables -I FORWARD -i "${BRIDGE_NAME}" -j ACCEPT 2>/dev/null || true
sudo iptables -I FORWARD -o "${BRIDGE_NAME}" -j ACCEPT 2>/dev/null || true

# Allow VM to reach the host's Docker registry on the bridge IP
sudo iptables -I INPUT -i "${BRIDGE_NAME}" -p tcp --dport "${REGISTRY_PORT}" -j ACCEPT 2>/dev/null || true

echo "=== Step 7: Reset VM image and EFI vars to force Ignition provisioning ==="
EFI_VARS="${SCRIPT_DIR}/flatcar_production_qemu_uefi_efi_vars.qcow2"
EFI_VARS_ORIG="${SCRIPT_DIR}/flatcar_production_qemu_uefi_efi_vars.qcow2.orig"
VM_IMAGE="${SCRIPT_DIR}/flatcar_production_qemu_uefi_image.img"
VM_IMAGE_ORIG="${SCRIPT_DIR}/flatcar_production_qemu_uefi_image.img.orig"

# Save pristine copies on first run
if [ ! -f "${EFI_VARS_ORIG}" ]; then
  cp "${EFI_VARS}" "${EFI_VARS_ORIG}"
  echo "Saved original EFI vars to ${EFI_VARS_ORIG}"
fi
if [ ! -f "${VM_IMAGE_ORIG}" ]; then
  cp "${VM_IMAGE}" "${VM_IMAGE_ORIG}"
  echo "Saved original VM image to ${VM_IMAGE_ORIG}"
fi

# Restore pristine copies so Ignition always runs on a clean first boot
cp "${EFI_VARS_ORIG}" "${EFI_VARS}"
echo "EFI vars reset — Ignition will run on this boot"
cp "${VM_IMAGE_ORIG}" "${VM_IMAGE}"
echo "VM image reset to pristine state"

echo "=== Step 8: Launch QEMU VM ==="
echo "VM will be accessible at ${VM_IP}:8080"
echo "  curl http://${VM_IP}:8080/api/task/list"
echo ""
echo "SSH access:"
echo "  ssh -i ${SSH_DIR}/service_ed25519 service@${VM_IP}  # service account (docker access)"

VM_NCPUS="$(getconf _NPROCESSORS_ONLN)"
VM_NAME="flatcar_production_qemu_uefi-4459-2-4"

qemu-system-x86_64 \
  -name "${VM_NAME}" \
  -m 2048 \
  -machine q35,accel=kvm:tcg,smm=on \
  -cpu host \
  -smp "${VM_NCPUS}" \
  -global ICH9-LPC.disable_s3=1 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive "if=pflash,unit=0,file=${SCRIPT_DIR}/flatcar_production_qemu_uefi_efi_code.qcow2,format=qcow2,readonly=on" \
  -drive "if=pflash,unit=1,file=${SCRIPT_DIR}/flatcar_production_qemu_uefi_efi_vars.qcow2,format=qcow2" \
  -drive "if=none,id=blk,file=${SCRIPT_DIR}/flatcar_production_qemu_uefi_image.img" \
  -device "virtio-blk-pci,drive=blk,bootindex=1" \
  -fw_cfg "name=opt/org.flatcar-linux/config,file=${SCRIPT_DIR}/config.ign" \
  -netdev "tap,id=tap0,ifname=${TAP_NAME},script=no,downscript=no" \
  -device "virtio-net-pci,netdev=tap0,mac=52:54:00:12:34:56" \
  -object rng-random,filename=/dev/urandom,id=rng0 \
  -device virtio-rng-pci,rng=rng0
