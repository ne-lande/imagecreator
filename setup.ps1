#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and launches a Flatcar Linux QEMU VM on Windows.
.DESCRIPTION
    Windows equivalent of setup.sh. Key differences from the Linux version:

    * Networking  - uses QEMU user-mode (SLIRP) networking instead of
                    TAP/bridge devices. No admin rights needed for networking.
                    Port 8080 (agent) and 22 (SSH) are forwarded to the host
                    by default; use -ForwardPorts to expose additional ports.
    * SSH keys    - generated with ssh-keygen (ships with Windows 10+/OpenSSH).
    * Butane      - downloaded automatically as a Windows binary if not found
                    in PATH.
    * Docker      - Docker Desktop for Windows is required.
    * KVM         - replaced by WHPX (Windows Hypervisor Platform) with TCG
                    fallback; enable WHPX in "Windows Features" for best speed.

.PARAMETER SkipBuild
    Skip building the crudeagent Docker image (use an existing local image).
.PARAMETER SkipPush
    Skip tagging and pushing the crudeagent image to the registry.
    Useful when the image is already present in the registry from a previous run.
.PARAMETER SkipAgent
    Convenience switch: skips both -SkipBuild and -SkipPush together.
    Use this when the agent image is already in the registry and you only want
    to (re)generate the Ignition config and launch the VM.
.PARAMETER SkipRegistry
    Skip starting the local Docker registry (assume it is already running).
    Ignored when -Registry points to Docker Hub (no local registry needed).
.PARAMETER Registry
    Docker registry used to distribute the crudeagent image to the VM.
    Default: "docker.io" (Docker Hub).

    - "docker.io"  (default) - image is pushed to Docker Hub as
                               <DockerHubUser>/crudeagent:latest and pulled
                               from there inside the VM. No local registry
                               container is started. Requires -DockerHubUser.
    - Any other value        - treated as a local/private registry address
                               (e.g. "192.168.1.5:5000" or "myregistry:5000").
                               A local registry container is started on
                               localhost:<RegistryPort> and the VM pulls from
                               10.0.2.2:<RegistryPort> via SLIRP.
.PARAMETER DockerHubUser
    Docker Hub username. Required when -Registry is "docker.io".
    The image will be pushed/pulled as <DockerHubUser>/crudeagent:latest.
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
.PARAMETER UseWhpx
    Try WHPX (Windows Hypervisor Platform) acceleration before falling back to
    TCG. By default only TCG is used to avoid the noisy WHPX warning on
    machines where the feature is not enabled.
    Enable "Windows Hypervisor Platform" in Windows Features and reboot, then
    pass this switch for near-native VM speed.
#>
[CmdletBinding()]
param(
    [switch]   $SkipBuild,
    [switch]   $SkipPush,
    [switch]   $SkipAgent,
    [switch]   $SkipRegistry,
    [string]   $Registry      = "docker.io",
    [string]   $DockerHubUser = "",
    [int]      $SshPort       = 2222,
    [int]      $AgentPort     = 8080,
    [int]      $Memory        = 2048,
    [string[]] $ForwardPorts  = @(),
    [switch]   $NoDisplay,
    [switch]   $UseWhpx
)

# -SkipAgent is a convenience alias for -SkipBuild + -SkipPush
if ($SkipAgent) {
    $SkipBuild = $true
    $SkipPush  = $true
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir  = $PSScriptRoot
$ProjectDir = Split-Path $ScriptDir -Parent
$SshDir     = Join-Path $ScriptDir ".ssh"

$EfiCode     = Join-Path $ScriptDir "flatcar_production_qemu_uefi_efi_code.qcow2"
$EfiVars     = Join-Path $ScriptDir "flatcar_production_qemu_uefi_efi_vars.qcow2"
$EfiVarsOrig = Join-Path $ScriptDir "flatcar_production_qemu_uefi_efi_vars.qcow2.orig"
$VmImage     = Join-Path $ScriptDir "flatcar_production_qemu_uefi_image.img"
$VmImageOrig = Join-Path $ScriptDir "flatcar_production_qemu_uefi_image.img.orig"
$ConfigYaml  = Join-Path $ScriptDir "config.yaml"
$ConfigIgn   = Join-Path $ScriptDir "config.ign"
$ConfigRendered = Join-Path $ScriptDir "config.yaml.rendered"

$RegistryPort = 5000

# ---------------------------------------------------------------------------
# Resolve registry mode
# ---------------------------------------------------------------------------
$UseDockerHub = ($Registry -eq "docker.io")

if ($UseDockerHub) {
    if ($DockerHubUser -eq "") {
        # Try to detect the username from the local Docker config (set by 'docker login').
        # This is only needed to construct the image name; the VM pulls anonymously
        # from a public image and does not require Docker Hub credentials itself.
        try {
            $dockerCfg = Get-Content (Join-Path $env:USERPROFILE ".docker\config.json") -Raw -ErrorAction Stop | ConvertFrom-Json
            $DockerHubUser = $dockerCfg.auths.'https://index.docker.io/v1/'.PSObject.Properties.Name | Select-Object -First 1
        } catch {}
        if ($DockerHubUser -eq "" -or $null -eq $DockerHubUser) {
            Write-Error (
                "Cannot determine Docker Hub username.`n" +
                "Supply it explicitly:  .\setup.ps1 -DockerHubUser <username>`n" +
                "Note: 'docker login' is only required on this host when pushing (-SkipAgent is NOT set).`n" +
                "The VM pulls the image anonymously from a public Docker Hub repository."
            )
        }
    }
    # Image the VM will pull from Docker Hub (public pull, no auth needed in VM)
    $AgentImage    = "${DockerHubUser}/crudeagent:latest"
    # Address the VM uses to reach the registry (public internet via SLIRP NAT)
    $VmRegistryRef = $AgentImage
    Write-Host "Registry mode: Docker Hub  ->  $AgentImage" -ForegroundColor Cyan
    if ($SkipPush) {
        Write-Host "  (push skipped - image must already be public on Docker Hub)" -ForegroundColor Yellow
    }
} else {
    # Custom / local registry
    # The VM reaches the host at 10.0.2.2 via SLIRP; replace any explicit host
    # address with 10.0.2.2 so the VM can pull from the local registry.
    $LocalRegistryHost = $Registry -replace '^[^:]+', '10.0.2.2'
    $AgentImage        = "localhost:${RegistryPort}/crudeagent:latest"
    $VmRegistryRef     = "${LocalRegistryHost}/crudeagent:latest"
    Write-Host "Registry mode: local/custom  ->  $Registry  (VM sees $VmRegistryRef)" -ForegroundColor Cyan
}

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
function Save-FileFromUrl {
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

    Write-Host "  butane not found in PATH - downloading Windows binary..." -ForegroundColor Yellow
    # Latest release from the Flatcar/Butane GitHub releases
    $ButaneUrl = "https://github.com/coreos/butane/releases/latest/download/butane-x86_64-pc-windows-gnu.exe"
    Save-FileFromUrl -Url $ButaneUrl -Dest $local
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
    Write-Host "Skipping build (-SkipBuild)" -ForegroundColor Yellow
} else {
    $NativeDockerfile = Join-Path $ProjectDir "crudeagent\native.Dockerfile"
    $CrudeagentCtx    = Join-Path $ProjectDir "crudeagent"
    & docker build -f $NativeDockerfile -t "crudeagent:latest" $CrudeagentCtx
    if ($LASTEXITCODE -ne 0) { Write-Error "docker build failed" }
}

# ---------------------------------------------------------------------------
# Step 3: Start local Docker registry (skipped for Docker Hub)
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3: Start local Docker registry ===" -ForegroundColor Cyan
if ($UseDockerHub) {
    Write-Host "Docker Hub mode - no local registry needed, skipping." -ForegroundColor Yellow
} elseif ($SkipRegistry) {
    Write-Host "Skipping registry start (-SkipRegistry)" -ForegroundColor Yellow
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
# Step 4: Tag and push image to registry
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 4: Tag and push image to registry ===" -ForegroundColor Cyan
if ($SkipPush) {
    Write-Host "Skipping tag/push (-SkipPush or -SkipAgent)" -ForegroundColor Yellow
    Write-Host "Assuming $AgentImage is already available in the registry." -ForegroundColor Yellow
} else {
    & docker tag "crudeagent:latest" $AgentImage
    if ($LASTEXITCODE -ne 0) { Write-Error "docker tag failed" }
    & docker push $AgentImage
    if ($LASTEXITCODE -ne 0) { Write-Error "docker push failed" }
    Write-Host "Pushed $AgentImage" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 5: Render Butane config and transpile to Ignition
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 5: Convert Butane config to Ignition ===" -ForegroundColor Cyan

# Patch the config:
#   - Replace the SSH key placeholder with the generated public key.
#   - Replace the registry address so the VM agent.service pulls from the
#     correct location:
#       Docker Hub mode  -> image ref is already a public Docker Hub name,
#                           no address substitution needed.
#       Local/custom     -> replace 192.168.100.1 with 10.0.2.2 (SLIRP host)
#                           and rewrite the image ref to $VmRegistryRef.
$ConfigContent = Get-Content $ConfigYaml -Raw
$ConfigContent = $ConfigContent -replace 'SERVICE_SSH_PUBLIC_KEY_PLACEHOLDER', $ServicePubkey

if ($UseDockerHub) {
    # Replace the local registry image reference with the Docker Hub image ref
    $ConfigContent = $ConfigContent -replace '192\.168\.100\.1:\d+/crudeagent:latest', $VmRegistryRef
    $ConfigContent = $ConfigContent -replace '192\.168\.100\.1:\d+', 'registry-1.docker.io'
    # Remove insecure-registries entry (not needed for Docker Hub)
    $ConfigContent = $ConfigContent -replace '"insecure-registries":\s*\["[^"]*"\]', '"insecure-registries": []'
} else {
    # Replace bridge IP with QEMU SLIRP host gateway
    $ConfigContent = $ConfigContent -replace '192\.168\.100\.1', '10.0.2.2'
}

# Write the rendered Butane YAML without BOM.
# PowerShell 5.1 Set-Content -Encoding UTF8 always prepends a UTF-8 BOM which
# causes Ignition's JSON parser to fail ("invalid character" error).
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($ConfigRendered, $ConfigContent, $Utf8NoBom)

$ButaneBin = Get-ButanePath
Write-Host "  Using butane: $ButaneBin"

# Run butane and redirect its stdout directly to config.ign via cmd /c so that
# PowerShell's string pipeline (which re-encodes and may add BOM/CRLF) is
# bypassed entirely. butane writes plain UTF-8 JSON with no BOM.
$ButaneEscaped = $ButaneBin  -replace '"', '""'
$RenderedEscaped = $ConfigRendered -replace '"', '""'
$IgnEscaped = $ConfigIgn -replace '"', '""'
cmd /c "`"$ButaneEscaped`" --strict `"$RenderedEscaped`" > `"$IgnEscaped`""
if ($LASTEXITCODE -ne 0) { Write-Error "butane transpilation failed" }

# Verify the output starts with '{' (no BOM)
$firstByte = [System.IO.File]::ReadAllBytes($ConfigIgn)[0]
if ($firstByte -ne 0x7B) {  # 0x7B = '{'
    # Strip BOM if present (EF BB BF)
    $rawBytes = [System.IO.File]::ReadAllBytes($ConfigIgn)
    if ($rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
        Write-Warning "BOM detected in config.ign output - stripping..."
        [System.IO.File]::WriteAllBytes($ConfigIgn, $rawBytes[3..($rawBytes.Length - 1)])
    } else {
        Write-Error "config.ign does not start with '{' (first byte: 0x$($firstByte.ToString('X2'))). Butane output may be invalid."
    }
}

Remove-Item $ConfigRendered -Force -ErrorAction SilentlyContinue
Write-Host "Ignition config written to config.ign (agent will pull $VmRegistryRef)" -ForegroundColor Green

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
Write-Host "EFI vars reset - Ignition will run on this boot" -ForegroundColor Green
Copy-Item $VmImageOrig $VmImage -Force
Write-Host "VM image reset to pristine state" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 7: Launch QEMU VM
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 7: Launch QEMU VM ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Build the -netdev hostfwd string.
#
# SLIRP user-mode networking: no TAP/bridge, no admin rights needed.
# The VM gets DHCP address 10.0.2.15; the host is reachable at 10.0.2.2.
#
# Always forwarded:
#   hostfwd=tcp::<SshPort>-:22     SSH access -> localhost:<SshPort>
#   hostfwd=tcp::<AgentPort>-:8080 agent API  -> localhost:<AgentPort>
#
# Extra ports via -ForwardPorts "hostPort:guestPort,..."
#   e.g. -ForwardPorts "3000:3000,5432:5432"
#   or   -ForwardPorts @("3000:3000","5432:5432")
# ---------------------------------------------------------------------------
$HostFwds = [System.Collections.Generic.List[string]]@(
    "hostfwd=tcp::${SshPort}-:22",
    "hostfwd=tcp::${AgentPort}-:8080"
)

# Normalise -ForwardPorts: accept both a comma-separated string and an array
$ExtraPorts = [System.Collections.Generic.List[string]]@()
foreach ($entry in $ForwardPorts) {
    foreach ($pair in ($entry -split ',')) {
        $pair = $pair.Trim()
        if ($pair -eq '') { continue }
        if ($pair -notmatch '^\d+:\d+$') {
            Write-Warning "Ignoring invalid port pair '$pair' (expected hostPort:guestPort)"
            continue
        }
        $hp, $gp = $pair -split ':'
        $HostFwds.Add("hostfwd=tcp::${hp}-:${gp}")
        $ExtraPorts.Add($pair)
    }
}

$NetdevStr = "user,id=net0," + ($HostFwds -join ',')

$VmName  = "flatcar_production_qemu_uefi-4593-2-1"
$NumCpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

Write-Host ""
Write-Host "VM will be accessible at:" -ForegroundColor Cyan
Write-Host "  Agent API : http://localhost:${AgentPort}/"
Write-Host "  SSH       : ssh -i `"$SshDir\service_ed25519`" -p $SshPort service@localhost"
if ($ExtraPorts.Count -gt 0) {
    Write-Host "  Extra port forwards (localhost -> VM):"
    foreach ($p in $ExtraPorts) {
        $hp, $gp = $p -split ':'
        Write-Host "    localhost:${hp} -> VM:${gp}" -ForegroundColor DarkCyan
    }
}
Write-Host ""
Write-Host "Starting QEMU (press Ctrl+C to stop)..." -ForegroundColor Yellow
Write-Host ""

# Build the QEMU argument list
$QemuArgs = @(
    "-name",    $VmName,
    "-m",       $Memory,
    # Machine / accelerator:
    #   Default: TCG only (software emulation, always works, no warning spam).
    #   Pass -UseWhpx to try WHPX first for near-native speed; requires
    #   "Windows Hypervisor Platform" to be enabled in Windows Features.
    "-machine", ("q35,accel=" + $(if ($UseWhpx) { "whpx:tcg" } else { "tcg" }) + ",smm=on"),
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
    # User-mode networking - all port forwards in one -netdev string
    "-netdev",  $NetdevStr,
    "-device",  "virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56",
    # RNG - use rng-builtin on Windows (rng-random requires /dev/urandom which does not exist on Windows)
    "-object",  "rng-builtin,id=rng0",
    "-device",  "virtio-rng-pci,rng=rng0"
)

# Display mode: SDL window by default, serial-only with -NoDisplay
if ($NoDisplay) {
    $QemuArgs += @("-nographic")
} else {
    $QemuArgs += @("-display", "sdl")
}

& qemu-system-x86_64 @QemuArgs
$ExitCode = $LASTEXITCODE

Write-Host "`nQEMU exited with code $ExitCode" -ForegroundColor $(if ($ExitCode -eq 0) { 'Green' } else { 'Red' })
