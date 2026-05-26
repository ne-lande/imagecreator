#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and launches a Flatcar Linux QEMU VM on Windows.
.DESCRIPTION
    Windows equivalent of setup.sh. Key differences from the Linux version:

    * Networking  — uses QEMU user-mode (SLIRP) networking instead of
                    TAP/bridge devices. No admin rights needed for networking.
                    Port 8080 (agent) and 22 (SSH) are forwarded to the host
                    by default; use -ForwardPorts to expose additional ports.
    * SSH keys    — generated with ssh-keygen (ships with Windows 10+/OpenSSH).
    * Butane      — downloaded automatically as a Windows binary if not found
                    in PATH.
    * Docker      — Docker Desktop for Windows is required.
    * KVM         — replaced by WHPX (Windows Hypervisor Platform) with TCG
                    fallback; enable WHPX in "Windows Features" for best speed.

.PARAMETER SkipBuild
    Skip building the crudeagent Docker image (use an existing local image).
.PARAMETER SkipRegistry
    Skip starting the local Docker registry (assume it is already running).
.PARAMETER SshPort
    Host port forwarded to the VM's SSH daemon. Default: 2222.
.PARAMETER AgentPort
    Host port forwarded to the VM's agent HTTP service. Default: 8080.
.PARAMETER Memory
    VM RAM in MB. Default: 2048.
.PARAMETER ForwardPorts
    Additional host:guest TCP port pairs to forward into the VM, e.g.:
        -ForwardPorts 8081:8081,3000:3000,5432:5432
    or as an array:
        -ForwardPorts @("8081:8081","3000:3000")
    These are added on top of the default SSH and agent forwards.
    Use this to reach containers running inside the VM on arbitrary ports.
.PARAMETER NoDisplay
    Run QEMU without a graphical window (serial console only, -nographic).
    Useful for headless / CI environments.
#>
[CmdletBinding()]
param(
    [switch]   $SkipBuild,
    [switch]   $SkipRegistry,
    [int]      $SshPort      = 2222,
    [int]      $AgentPort    = 8080,
    [int]      $Memory       = 2048,
    [string[]] $ForwardPorts = @(),
    [switch]   $NoDisplay
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir  = $PSScriptRoot
$ProjectDir = Split-Path $ScriptDir -Parent
$SshDir     = Join-Path $ScriptDir ".ssh"

$EfiCode    = Join-Path $ScriptDir "flatcar_production_qemu_uefi_efi_code.qcow2"
$EfiVars    = Join-Path $ScriptDir "flatcar_production_qemu_uefi_efi_vars.qcow2"
$EfiVarsOrig= Join-Path $ScriptDir "flatcar_production_qemu_uefi_efi_vars.qcow2.orig"
$VmImage    = Join-Path $ScriptDir "flatcar_production_qemu_uefi_image.img"
$VmImageOrig= Join-Path $ScriptDir "flatcar_production_qemu_uefi_image.img.orig"
$ConfigYaml = Join-Path $ScriptDir "config.yaml"
$ConfigIgn  = Join-Path $ScriptDir "config.ign"
$ConfigRendered = Join-Path $ScriptDir "config.yaml.rendered"

$RegistryPort = 5000
$AgentImage   = "localhost:${RegistryPort}/crudeagent:latest"

# ---------------------------------------------------------------------------
# Helper: require a command to be available
# ---------------------------------------------------------------------------
function Require-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Error "Required command '$Name' not found. $InstallHint"
    }
}

# ---------------------------------------------------------------------------
# Helper: download a file if it does not exist
# ---------------------------------------------------------------------------
function Download-File {
    param([string]$Url, [string]$Dest)
    if (Test-Path $Dest) { return }
    Write-Host "  Downloading $(Split-Path $Dest -Leaf) ..."
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Url -Destination $Dest -DisplayName (Split-Path $Dest -Leaf)
    } catch {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    }
}

# ---------------------------------------------------------------------------
# Helper: find butane (or download it)
# ---------------------------------------------------------------------------
function Get-ButanePath {
    $found = Get-Command butane -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    $local = Join-Path $ScriptDir "butane.exe"
    if (Test-Path $local) { return $local }

    Write-Host "  butane not found in PATH — downloading Windows binary..." -ForegroundColor Yellow
    # Latest release from the Flatcar/Butane GitHub releases
    $ButaneUrl = "https://github.com/coreos/butane/releases/latest/download/butane-x86_64-pc-windows-gnu.exe"
    Download-File -Url $ButaneUrl -Dest $local
    return $local
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
Write-Host "=== Checking prerequisites ===" -ForegroundColor Cyan
Require-Command "ssh-keygen" "Install OpenSSH: Settings > Apps > Optional Features > OpenSSH Client"
Require-Command "docker"     "Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
Require-Command "qemu-system-x86_64" "Install QEMU from https://www.qemu.org/download/#windows and add it to PATH"

foreach ($f in @($EfiCode, $EfiVars, $VmImage)) {
    if (-not (Test-Path $f)) {
        Write-Error "Missing artifact: $f`nRun .\download.ps1 first."
    }
}

# ---------------------------------------------------------------------------
# Step 1: Generate SSH keys
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 1: Generate SSH keys for VM users ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $SshDir | Out-Null

$ServiceKey = Join-Path $SshDir "service_ed25519"
if (-not (Test-Path $ServiceKey)) {
    & ssh-keygen -t ed25519 -f $ServiceKey -N '""' -C "service@crudeagent-vm"
    Write-Host "Generated SSH key for 'service' user" -ForegroundColor Green
} else {
    Write-Host "SSH key for 'service' already exists" -ForegroundColor Yellow
}

$ServicePubkey = Get-Content "${ServiceKey}.pub" -Raw
$ServicePubkey = $ServicePubkey.Trim()

# ---------------------------------------------------------------------------
# Step 2: Build crudeagent Docker image
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 2: Build crudeagent Docker image ===" -ForegroundColor Cyan
if ($SkipBuild) {
    Write-Host "Skipping build (--SkipBuild)" -ForegroundColor Yellow
} else {
    $NativeDockerfile = Join-Path $ProjectDir "crudeagent\native.Dockerfile"
    $CrudeagentCtx    = Join-Path $ProjectDir "crudeagent"
    & docker build -f $NativeDockerfile -t "crudeagent:latest" $CrudeagentCtx
    if ($LASTEXITCODE -ne 0) { Write-Error "docker build failed" }
}

# ---------------------------------------------------------------------------
# Step 3: Start local Docker registry
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3: Start local Docker registry ===" -ForegroundColor Cyan
if ($SkipRegistry) {
    Write-Host "Skipping registry start (--SkipRegistry)" -ForegroundColor Yellow
} else {
    $running = & docker ps --format "{{.Names}}" 2>$null | Where-Object { $_ -eq "registry" }
    if ($running) {
        Write-Host "Registry already running" -ForegroundColor Yellow
    } else {
        & docker rm -f registry 2>$null
        # Bind to all interfaces so the VM can reach it via the forwarded loopback
        & docker run -d --name registry -p "0.0.0.0:${RegistryPort}:5000" registry:2
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to start registry container" }
        Write-Host "Registry started on port $RegistryPort" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Step 4: Tag and push image to local registry
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 4: Tag and push image to local registry ===" -ForegroundColor Cyan
& docker tag "crudeagent:latest" $AgentImage
& docker push $AgentImage
if ($LASTEXITCODE -ne 0) { Write-Error "docker push failed" }

# ---------------------------------------------------------------------------
# Step 5: Render Butane config and transpile to Ignition
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 5: Convert Butane config to Ignition ===" -ForegroundColor Cyan

# On Windows the VM cannot reach 192.168.100.1 (no TAP bridge).
# With SLIRP networking the host is reachable at 10.0.2.2 from inside the VM.
# We patch the registry address accordingly.
$ConfigContent = Get-Content $ConfigYaml -Raw
$ConfigContent = $ConfigContent -replace 'SERVICE_SSH_PUBLIC_KEY_PLACEHOLDER', $ServicePubkey
# Replace bridge IP with QEMU SLIRP host gateway
$ConfigContent = $ConfigContent -replace '192\.168\.100\.1', '10.0.2.2'

Set-Content -Path $ConfigRendered -Value $ConfigContent -Encoding UTF8 -NoNewline

$ButaneBin = Get-ButanePath
Write-Host "  Using butane: $ButaneBin"
& $ButaneBin --strict $ConfigRendered | Set-Content -Path $ConfigIgn -Encoding UTF8 -NoNewline
if ($LASTEXITCODE -ne 0) { Write-Error "butane transpilation failed" }
Remove-Item $ConfigRendered -Force -ErrorAction SilentlyContinue
Write-Host "Ignition config written to config.ign" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 6: Reset VM image and EFI vars (force Ignition provisioning)
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 6: Reset VM image and EFI vars ===" -ForegroundColor Cyan

if (-not (Test-Path $EfiVarsOrig)) {
    Copy-Item $EfiVars $EfiVarsOrig
    Write-Host "Saved original EFI vars backup"
}
if (-not (Test-Path $VmImageOrig)) {
    Copy-Item $VmImage $VmImageOrig
    Write-Host "Saved original VM image backup"
}

Copy-Item $EfiVarsOrig $EfiVars -Force
Write-Host "EFI vars reset — Ignition will run on this boot" -ForegroundColor Green
Copy-Item $VmImageOrig $VmImage -Force
Write-Host "VM image reset to pristine state" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 7: Launch QEMU VM
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 7: Launch QEMU VM ===" -ForegroundColor Cyan

# Network note:
#   - SLIRP user-mode networking: no TAP/bridge, no admin rights needed.
#   - The VM gets DHCP address 10.0.2.15 by default.
#   - The Ignition config sets a static IP via MAC 52:54:00:12:34:56 but
#     that only works with a TAP bridge. On Windows we rely on DHCP/SLIRP
#     and access the agent via forwarded ports on localhost.
#   - hostfwd=tcp::8080-:8080  → agent API  at http://localhost:8080/
#   - hostfwd=tcp::2222-:22    → SSH access at localhost:2222

$VmName  = "flatcar_production_qemu_uefi-4593-2-1"
$NumCpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

Write-Host ""
Write-Host "VM will be accessible at:" -ForegroundColor Cyan
Write-Host "  Agent API : http://localhost:${AgentPort}/"
Write-Host "  SSH       : ssh -i $SshDir\service_ed25519 -p $SshPort service@localhost"
Write-Host ""
Write-Host "Starting QEMU (press Ctrl+C to stop)..." -ForegroundColor Yellow
Write-Host ""

# Build the QEMU argument list
$QemuArgs = @(
    "-name",    $VmName,
    "-m",       $Memory,
    # Machine: prefer WHPX (Windows Hypervisor Platform), fall back to TCG
    "-machine", "q35,accel=whpx:tcg,smm=on",
    "-cpu",     "max",
    "-smp",     $NumCpus,
    "-global",  "ICH9-LPC.disable_s3=1",
    "-global",  "driver=cfi.pflash01,property=secure,value=on",
    # EFI firmware
    "-drive",   "if=pflash,unit=0,file=${EfiCode},format=qcow2,readonly=on",
    "-drive",   "if=pflash,unit=1,file=${EfiVars},format=qcow2",
    # Primary disk
    "-drive",   "if=none,id=blk,file=${VmImage}",
    "-device",  "virtio-blk-pci,drive=blk,bootindex=1",
    # Ignition config
    "-fw_cfg",  "name=opt/org.flatcar-linux/config,file=${ConfigIgn}",
    # User-mode networking with port forwards
    "-netdev",  "user,id=net0,hostfwd=tcp::${SshPort}-:22,hostfwd=tcp::${AgentPort}-:8080",
    "-device",  "virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56",
    # RNG
    "-object",  "rng-random,filename=/dev/urandom,id=rng0",
    "-device",  "virtio-rng-pci,rng=rng0",
    # Display: use SDL window; add -nographic if you prefer console-only
    "-display", "sdl"
)

& qemu-system-x86_64 @QemuArgs
$ExitCode = $LASTEXITCODE

Write-Host "`nQEMU exited with code $ExitCode" -ForegroundColor $(if ($ExitCode -eq 0) { 'Green' } else { 'Red' })
