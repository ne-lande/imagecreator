#!/bin/bash
set -euo pipefail

arch="amd64"
VERSION="4593.2.1"
BASE="https://stable.release.flatcar-linux.net/${arch}-usr/${VERSION}"

echo "Downloading Flatcar ${VERSION} for ${arch}..."

wget -O flatcar_production_qemu_uefi.sh "${BASE}/flatcar_production_qemu_uefi.sh"
wget -O flatcar_production_qemu_uefi_efi_code.qcow2 "${BASE}/flatcar_production_qemu_uefi_efi_code.qcow2"
wget -O flatcar_production_qemu_uefi_efi_vars.qcow2 "${BASE}/flatcar_production_qemu_uefi_efi_vars.qcow2"
wget -O flatcar_production_qemu_uefi_image.img "${BASE}/flatcar_production_qemu_uefi_image.img"

chmod 755 flatcar_production_qemu_uefi.sh

# Save pristine backups used by setup.sh to reset state before each boot
cp flatcar_production_qemu_uefi_efi_vars.qcow2 flatcar_production_qemu_uefi_efi_vars.qcow2.orig
cp flatcar_production_qemu_uefi_image.img flatcar_production_qemu_uefi_image.img.orig

echo "Done. Pristine .orig backups created."
