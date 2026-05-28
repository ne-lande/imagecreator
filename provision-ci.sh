#!/bin/bash
# CI-only provisioning: boots Flatcar headlessly via QEMU user-mode networking,
# waits for Ignition to complete (SSH up), then shuts down and leaves the
# provisioned image ready for upload.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_DIR="${SCRIPT_DIR}/.ssh"

EFI_CODE="${SCRIPT_DIR}/flatcar_production_qemu_uefi_efi_code.qcow2"
EFI_VARS="${SCRIPT_DIR}/flatcar_production_qemu_uefi_efi_vars.qcow2"
EFI_VARS_ORIG="${SCRIPT_DIR}/flatcar_production_qemu_uefi_efi_vars.qcow2.orig"
VM_IMAGE="${SCRIPT_DIR}/flatcar_production_qemu_uefi_image.img"
VM_IMAGE_ORIG="${SCRIPT_DIR}/flatcar_production_qemu_uefi_image.img.orig"
QEMU_PID_FILE="${SCRIPT_DIR}/qemu.pid"

SSH_PORT=2222
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5"
SSH_KEY="${SSH_DIR}/service_ed25519"

cleanup() {
    if [ -f "${QEMU_PID_FILE}" ]; then
        PID=$(cat "${QEMU_PID_FILE}")
        echo "Stopping QEMU (PID ${PID})..."
        kill "${PID}" 2>/dev/null || true
        rm -f "${QEMU_PID_FILE}"
    fi
}
trap cleanup EXIT

echo "=== Step 1: Generate SSH key ==="
mkdir -p "${SSH_DIR}"
if [ ! -f "${SSH_KEY}" ]; then
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "service@flatcar-ci"
    echo "Generated SSH key"
else
    echo "SSH key already exists"
fi
SERVICE_PUBKEY=$(cat "${SSH_KEY}.pub")

echo "=== Step 2: Convert butane config to ignition ==="
sed "s|SERVICE_SSH_PUBLIC_KEY_PLACEHOLDER|${SERVICE_PUBKEY}|g" \
    "${SCRIPT_DIR}/config.yaml" > "${SCRIPT_DIR}/config.yaml.rendered"
butane --strict "${SCRIPT_DIR}/config.yaml.rendered" > "${SCRIPT_DIR}/config.ign"
rm -f "${SCRIPT_DIR}/config.yaml.rendered"

echo "=== Step 3: Restore pristine images ==="
cp "${EFI_VARS_ORIG}" "${EFI_VARS}"
cp "${VM_IMAGE_ORIG}" "${VM_IMAGE}"

echo "=== Step 4: Boot QEMU (user-mode networking, no display) ==="
qemu-system-x86_64 \
    -name flatcar-provision \
    -m 2048 \
    -machine q35,accel=kvm:tcg,smm=on \
    -cpu host \
    -smp 2 \
    -global ICH9-LPC.disable_s3=1 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,unit=0,file=${EFI_CODE},format=qcow2,readonly=on" \
    -drive "if=pflash,unit=1,file=${EFI_VARS},format=qcow2" \
    -drive "if=none,id=blk,file=${VM_IMAGE}" \
    -device "virtio-blk-pci,drive=blk,bootindex=1" \
    -fw_cfg "name=opt/org.flatcar-linux/config,file=${SCRIPT_DIR}/config.ign" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-pci,rng=rng0 \
    -display none \
    -serial file:"${SCRIPT_DIR}/qemu-console.log" \
    > "${SCRIPT_DIR}/qemu.log" 2>&1 &
echo $! > "${QEMU_PID_FILE}"
echo "QEMU started (PID $(cat "${QEMU_PID_FILE}"))"

echo "=== Step 5: Wait for SSH — up to 10 minutes ==="
for i in $(seq 1 60); do
    if ssh ${SSH_OPTS} -i "${SSH_KEY}" -p "${SSH_PORT}" service@localhost "echo ok" 2>/dev/null; then
        echo "SSH is up — Ignition provisioning complete"
        break
    fi
    if [ "${i}" -eq 60 ]; then
        echo "ERROR: SSH never became available. Console log:"
        tail -50 "${SCRIPT_DIR}/qemu-console.log" || true
        exit 1
    fi
    echo "Attempt ${i}/60, retrying in 10s..."
    sleep 10
done

echo "=== Step 6: Shut down VM ==="
ssh ${SSH_OPTS} -i "${SSH_KEY}" -p "${SSH_PORT}" service@localhost \
    "sudo systemctl poweroff" || true

PID=$(cat "${QEMU_PID_FILE}" 2>/dev/null || echo "")
if [ -n "${PID}" ]; then
    echo "Waiting for QEMU to exit cleanly..."
    for i in $(seq 1 30); do
        kill -0 "${PID}" 2>/dev/null || { echo "QEMU exited cleanly"; break; }
        sleep 2
    done
    kill "${PID}" 2>/dev/null || true
fi
rm -f "${QEMU_PID_FILE}"

echo "=== Done: provisioned images ready ==="
echo "  ${VM_IMAGE}"
echo "  ${EFI_VARS}"
