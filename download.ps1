#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads Flatcar Linux QEMU UEFI artifacts for Windows.
.DESCRIPTION
    Fetches the Flatcar production QEMU UEFI image, EFI firmware blobs,
    and the upstream launch wrapper from the Flatcar stable release CDN.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Arch    = "amd64"
$Version = "4593.2.1"
$Base    = "https://stable.release.flatcar-linux.net/${Arch}-usr/${Version}"

$Files = @(
    "flatcar_production_qemu_uefi.sh",
    "flatcar_production_qemu_uefi_efi_code.qcow2",
    "flatcar_production_qemu_uefi_efi_vars.qcow2",
    "flatcar_production_qemu_uefi_image.img"
)

Write-Host "Downloading Flatcar ${Version} for ${Arch}..." -ForegroundColor Cyan

foreach ($File in $Files) {
    $Url  = "${Base}/${File}"
    $Dest = Join-Path $PSScriptRoot $File
    if (Test-Path $Dest) {
        Write-Host "  [skip] $File already exists" -ForegroundColor Yellow
    } else {
        Write-Host "  Downloading $File ..."
        # Use BITS for large files when available, fall back to Invoke-WebRequest
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            Start-BitsTransfer -Source $Url -Destination $Dest -DisplayName $File
        } catch {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
        }
        Write-Host "  [done]  $File" -ForegroundColor Green
    }
}

# Save pristine backups used by setup.ps1 to reset state before each boot
$EfiVars   = Join-Path $PSScriptRoot "flatcar_production_qemu_uefi_efi_vars.qcow2"
$EfiOrig   = Join-Path $PSScriptRoot "flatcar_production_qemu_uefi_efi_vars.qcow2.orig"
$VmImage   = Join-Path $PSScriptRoot "flatcar_production_qemu_uefi_image.img"
$VmOrig    = Join-Path $PSScriptRoot "flatcar_production_qemu_uefi_image.img.orig"

if (-not (Test-Path $EfiOrig)) {
    Copy-Item $EfiVars $EfiOrig
    Write-Host "Pristine EFI vars backup created." -ForegroundColor Green
}
if (-not (Test-Path $VmOrig)) {
    Copy-Item $VmImage $VmOrig
    Write-Host "Pristine VM image backup created." -ForegroundColor Green
}

Write-Host "`nDone. Run .\setup.ps1 to build and launch the VM." -ForegroundColor Cyan
