#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-shot Windows installer for the Flatcar VM environment.
.DESCRIPTION
    1. Checks for QEMU and installs it via winget (or a direct download) if missing.
    2. Downloads the prebuilt provisioned Flatcar image from a URL or via the
       GitHub Actions API, then fetches the read-only EFI firmware from the
       Flatcar CDN if needed.
    3. Writes a vm-autostart.ps1 launcher and registers a Windows Task Scheduler
       task that starts the VM at every system boot.
    4. Adds a hostname entry to the Windows hosts file pointing to 127.0.0.1
       (the VM is reached via QEMU SLIRP port forwarding).
    5. Prints a colour-coded installation summary.

    Run as Administrator: required for the hosts file and the scheduled task.

.PARAMETER ImageUrl
    HTTPS URL to either:
      * a ZIP / tar(.gz|.xz) archive containing the provisioned image files
        (flatcar_production_qemu_uefi_image.img and
         flatcar_production_qemu_uefi_efi_vars.qcow2), or
      * a single raw image file (.img or .qcow2). Use -EfiVarsUrl in
        addition to provide the matching EFI vars file; otherwise the
        pristine EFI vars from the Flatcar CDN are downloaded.
    Typical sources: a GitHub Actions artifact download link, a release
    asset on GitHub, an S3 object, or any plain HTTP(S) URL.
    If this parameter and -GitHubRepo are both omitted, the script checks
    for existing local files and errors out if none are found.
.PARAMETER EfiVarsUrl
    Optional HTTPS URL to a prebuilt EFI vars qcow2 file that pairs with
    -ImageUrl when the latter points to a raw .img file rather than an
    archive. Ignored when -ImageUrl is an archive.
.PARAMETER GitHubRepo
    GitHub repository in "owner/repo" form.  When set (and -ImageUrl is empty),
    the script calls the GitHub Actions API to locate the newest
    "flatcar-provisioned-*" artifact and download it automatically.
.PARAMETER GitHubToken
    Personal access token with repo + actions:read scopes.
    Required for private repositories; optional for public ones.
.PARAMETER InstallDir
    Directory where image files are stored and the launcher script is written.
    Defaults to the directory that contains install.ps1.
.PARAMETER VmHostname
    Hostname added to the Windows hosts file, resolving to 127.0.0.1.
    Default: crudeagent.local
.PARAMETER AgentPort
    Host TCP port forwarded to the VM's HTTP agent (guest port 8080).
    Default: 8080.
.PARAMETER SshPort
    Host TCP port forwarded to the VM's SSH daemon (guest port 22).
    Default: 2222.
.PARAMETER ExtraPort
    Extra host TCP port forwarded 1:1 to the VM (host port == guest port).
    Default: 7891.  Set to 0 to disable.
.PARAMETER TaskName
    Name of the Windows scheduled task used for VM autostart.
    Default: FlatcarVM.
.PARAMETER NoAutostart
    Skip writing the launcher script and registering the scheduled task.
.PARAMETER UseWhpx
    Prefer WHPX (Windows Hypervisor Platform) over TCG software emulation.
    Requires "Windows Hypervisor Platform" in Windows Features and a reboot.
#>
[CmdletBinding()]
param(
    [string] $ImageUrl    = "",
    [string] $EfiVarsUrl  = "",
    [string] $GitHubRepo  = "",
    [string] $GitHubToken = "",
    [string] $InstallDir  = $PSScriptRoot,
    [string] $VmHostname  = "crudeagent.local",
    [int]    $AgentPort   = 8080,
    [int]    $SshPort     = 2222,
    [int]    $ExtraPort   = 7891,
    [string] $TaskName    = "FlatcarVM",
    [switch] $NoAutostart,
    [switch] $UseWhpx
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EfiCode         = Join-Path $InstallDir "flatcar_production_qemu_uefi_efi_code.qcow2"
$EfiVars         = Join-Path $InstallDir "flatcar_production_qemu_uefi_efi_vars.qcow2"
$VmImage         = Join-Path $InstallDir "flatcar_production_qemu_uefi_image.img"
$AutostartScript = Join-Path $InstallDir "vm-autostart.ps1"
$HostsFile       = "C:\Windows\System32\drivers\etc\hosts"

$FlatcarVersion  = "4593.2.1"
$FlatcarArch     = "amd64"
$FlatcarCdnBase  = "https://stable.release.flatcar-linux.net/${FlatcarArch}-usr/${FlatcarVersion}"

$Results = [ordered]@{
    "QEMU"           = "pending"
    "Provisioned image" = "pending"
    "EFI firmware"   = "pending"
    "Autostart task" = "pending"
    "Hosts entry"    = "pending"
}

function Write-Step([string]$Text) {
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    Write-Host "  [ok]   $Text" -ForegroundColor Green
}

function Write-Skip([string]$Text) {
    Write-Host "  [skip] $Text" -ForegroundColor Yellow
}

function Write-Fail([string]$Text) {
    Write-Host "  [FAIL] $Text" -ForegroundColor Red
}

function Save-File {
    param(
        [string]    $Url,
        [string]    $Dest,
        [hashtable] $Headers = @{}
    )
    Write-Host "  Downloading $(Split-Path $Dest -Leaf) ..."
    try {
        if ($Headers.Count -gt 0) { throw "BITS does not support custom headers" }
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Url -Destination $Dest -DisplayName (Split-Path $Dest -Leaf)
    } catch {
        $params = @{ Uri = $Url; OutFile = $Dest; UseBasicParsing = $true }
        if ($Headers.Count -gt 0) { $params.Headers = $Headers }
        Invoke-WebRequest @params
    }
}

function Find-Qemu {
    $cmd = Get-Command "qemu-system-x86_64" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $default = "C:\Program Files\qemu\qemu-system-x86_64.exe"
    if (Test-Path $default) { return $default }
    return $null
}


Write-Step "Step 1: Check for QEMU"

$QemuBin = Find-Qemu
if ($QemuBin) {
    $ver = (& $QemuBin --version 2>&1 | Select-Object -First 1)
    Write-Ok "Found: $QemuBin"
    Write-Host "       $ver" -ForegroundColor DarkGray
    $Results["QEMU"] = "already installed - $ver"
} else {
    Write-Host "  QEMU not found - attempting install via winget..." -ForegroundColor Yellow

    $installed = $false
    $winget = Get-Command "winget" -ErrorAction SilentlyContinue
    if ($winget) {
        # The QEMU package is published under the "SoftwareFreedomConservancy"
        # namespace in the official winget-pkgs community repo.
        # ("QEMU.QEMU" - which used to exist - returns "No package found".)
        $proc = Start-Process "winget" `
            -ArgumentList "install --id SoftwareFreedomConservancy.QEMU --source winget --silent --accept-package-agreements --accept-source-agreements" `
            -Wait -PassThru -NoNewWindow
        # 0 = success, -1978335212 (0x8A150014) = already installed
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335212) {
            $installed = $true
        } else {
            Write-Host "  winget exited $($proc.ExitCode); trying direct download..." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  winget not available; using direct download..." -ForegroundColor Yellow
    }

    if (-not $installed) {
        # Stable build from Stefan Weil's Windows QEMU builds (official QEMU project mirror)
        $InstallerUrl  = "https://qemu.weilnetz.de/w64/qemu-w64-setup-20241222.exe"
        $InstallerPath = Join-Path $env:TEMP "qemu-setup.exe"
        Save-File -Url $InstallerUrl -Dest $InstallerPath
        Write-Host "  Running installer silently..."
        $proc = Start-Process $InstallerPath -ArgumentList "/S" -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Error "QEMU installer exited with code $($proc.ExitCode). Aborting."
        }
        $installed = $true
    }

    if ($installed) {
        # Reload PATH for this session so Find-Qemu can pick up the new binary.
        $env:PATH = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                    [Environment]::GetEnvironmentVariable("PATH", "User")
        $QemuBin = Find-Qemu
        if ($QemuBin) {
            $ver = (& $QemuBin --version 2>&1 | Select-Object -First 1)
            Write-Ok "Installed: $QemuBin"
            Write-Host "           $ver" -ForegroundColor DarkGray
            $Results["QEMU"] = "installed - $ver"
        } else {
            Write-Fail "Installed but binary not found. Add 'C:\Program Files\qemu' to PATH."
            $QemuBin = "C:\Program Files\qemu\qemu-system-x86_64.exe"
            $Results["QEMU"] = "installed (PATH refresh may be needed)"
        }
    }
}


Write-Step "Step 2: Download provisioned Flatcar image"

$imagePresent = (Test-Path $EfiVars) -and (Test-Path $VmImage)

if ($imagePresent) {
    Write-Skip "Provisioned image files already exist in $InstallDir"
    $Results["Provisioned image"] = "already present"
} elseif ($ImageUrl -ne "") {
    $dlHeaders = @{ "Accept" = "application/octet-stream" }
    if ($GitHubToken -ne "") { $dlHeaders["Authorization"] = "Bearer $GitHubToken" }

    # Detect content type by the URL path (ignore query string).
    $urlPath = ([uri]$ImageUrl).AbsolutePath.ToLowerInvariant()
    $isArchive = $urlPath -match '\.(zip|tar|tar\.gz|tgz|tar\.xz|txz)$'
    $isRawImg  = $urlPath -match '\.(img|raw)$'
    $isQcow    = $urlPath -match '\.qcow2$'

    if ($isArchive -or -not ($isRawImg -or $isQcow)) {
        # Treat unknown extensions as ZIP archives for backward compatibility.
        # IMPORTANT: Expand-Archive requires the file to end in ".zip" or it
        # fails with "The archive file ... is not in the supported format."
        # Pick an on-disk extension that matches the URL so the right
        # extractor (Expand-Archive vs tar) sees a recognisable filename.
        if     ($urlPath -match '\.(tar\.gz|tgz)$') { $ext = ".tar.gz" }
        elseif ($urlPath -match '\.(tar\.xz|txz)$') { $ext = ".tar.xz" }
        elseif ($urlPath -match '\.tar$')          { $ext = ".tar" }
        else                                        { $ext = ".zip" }
        $archive = Join-Path $env:TEMP ("flatcar-provisioned-download" + $ext)
        if (Test-Path $archive) { Remove-Item $archive -Force }
        Save-File -Url $ImageUrl -Dest $archive -Headers $dlHeaders
        Write-Host "  Extracting to $InstallDir ..."
        if ($ext -eq ".zip") {
            Expand-Archive -LiteralPath $archive -DestinationPath $InstallDir -Force
        } else {
            # tar variants - use the bundled tar.exe (Windows 10 1803+).
            & tar -xf $archive -C $InstallDir
            if ($LASTEXITCODE -ne 0) { Write-Error "tar extraction failed" }
        }
        Remove-Item $archive -Force
        Write-Ok "Provisioned image extracted"
        $Results["Provisioned image"] = "downloaded from URL (archive)"
    } else {
        # Direct download of a single raw image file.
        if ($isRawImg) { $dest = $VmImage } else { $dest = $EfiVars }
        Save-File -Url $ImageUrl -Dest $dest -Headers $dlHeaders
        Write-Ok "Image downloaded to $(Split-Path $dest -Leaf)"

        if ($EfiVarsUrl -ne "") {
            $efiHeaders = @{ "Accept" = "application/octet-stream" }
            if ($GitHubToken -ne "") { $efiHeaders["Authorization"] = "Bearer $GitHubToken" }
            Save-File -Url $EfiVarsUrl -Dest $EfiVars -Headers $efiHeaders
            Write-Ok "EFI vars downloaded from -EfiVarsUrl"
        } elseif (-not (Test-Path $EfiVars)) {
            $efiVarsCdn = "${FlatcarCdnBase}/flatcar_production_qemu_uefi_efi_vars.qcow2"
            Save-File -Url $efiVarsCdn -Dest $EfiVars
            Write-Ok "EFI vars downloaded from Flatcar CDN"
        }
        $Results["Provisioned image"] = "downloaded from URL (raw image)"
    }
} elseif ($GitHubRepo -ne "") {
    Write-Host "  Querying GitHub Actions API for latest artifact in $GitHubRepo ..."
    $apiHeaders = @{
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if ($GitHubToken -ne "") { $apiHeaders["Authorization"] = "Bearer $GitHubToken" }

    $apiUrl   = "https://api.github.com/repos/${GitHubRepo}/actions/artifacts?per_page=20"
    $response = (Invoke-WebRequest -Uri $apiUrl -Headers $apiHeaders -UseBasicParsing).Content | ConvertFrom-Json
    $artifact = $response.artifacts |
        Where-Object { $_.name -like "flatcar-provisioned-*" -and $_.expired -eq $false } |
        Sort-Object created_at -Descending |
        Select-Object -First 1

    if ($null -eq $artifact) {
        Write-Fail "No 'flatcar-provisioned-*' artifact found in $GitHubRepo."
        Write-Host "  Run the 'Build Provisioned Flatcar Image' workflow first," -ForegroundColor Yellow
        Write-Host "  or supply a direct URL via -ImageUrl." -ForegroundColor Yellow
        $Results["Provisioned image"] = "not found - run the CI workflow first"
    } else {
        Write-Host "  Found: $($artifact.name)  (created $($artifact.created_at))"
        $archive = Join-Path $env:TEMP "flatcar-provisioned.zip"
        Save-File -Url $artifact.archive_download_url -Dest $archive -Headers $apiHeaders
        Write-Host "  Extracting to $InstallDir ..."
        Expand-Archive -Path $archive -DestinationPath $InstallDir -Force
        Remove-Item $archive -Force
        Write-Ok "Provisioned image extracted"
        $Results["Provisioned image"] = "downloaded - $($artifact.name)"
    }
} else {
    Write-Fail "Image files not found and no download source provided."
    Write-Host "  Options:" -ForegroundColor Yellow
    Write-Host "    -ImageUrl    <direct ZIP url>" -ForegroundColor Yellow
    Write-Host "    -GitHubRepo  owner/repo  [-GitHubToken token]" -ForegroundColor Yellow
    Write-Host "  Or build locally with:  .\download.ps1  then  .\setup.ps1" -ForegroundColor Yellow
    $Results["Provisioned image"] = "missing - no source specified"
}


Write-Step "Step 3: Check EFI firmware"

if (Test-Path $EfiCode) {
    Write-Skip "EFI code firmware already present"
    $Results["EFI firmware"] = "already present"
} else {
    $efiUrl = "${FlatcarCdnBase}/flatcar_production_qemu_uefi_efi_code.qcow2"
    Save-File -Url $efiUrl -Dest $EfiCode
    Write-Ok "EFI firmware downloaded from Flatcar CDN"
    $Results["EFI firmware"] = "downloaded from Flatcar CDN (v$FlatcarVersion)"
}


Write-Step "Step 4: Register autostart task"

if ($NoAutostart) {
    Write-Skip "Skipping autostart registration (-NoAutostart)"
    $Results["Autostart task"] = "skipped"
} else {
    $QemuExe = if ($QemuBin) { $QemuBin } else { "C:\Program Files\qemu\qemu-system-x86_64.exe" }
    $Accel   = if ($UseWhpx) { "whpx:tcg" } else { "tcg" }
    $LogFile = Join-Path $InstallDir "vm.log"

    # Build the launcher script content with all paths baked in as string literals.
    # Single-quote doubling ('') is how you embed a literal ' inside a PS string.
    $launcherLines = @(
        "# Auto-generated by install.ps1 - do not edit manually."
        "# Starts the Flatcar VM in the background at system boot."
        ""
        'Start-Process -FilePath "' + ($QemuExe   -replace '"', '`"') + '" `'
        '    -WindowStyle Hidden -NoNewWindow `'
        '    -RedirectStandardOutput "' + ($LogFile -replace '"', '`"') + '" `'
        '    -RedirectStandardError  "' + ($LogFile -replace '"', '`"') + '" `'
        '    -ArgumentList @('
        "        '-name',    'flatcar-vm',"
        "        '-m',       '2048',"
        "        '-machine', 'q35,accel=$Accel,smm=on',"
        "        '-cpu',     'max',"
        "        '-smp',     '2',"
        "        '-global',  'ICH9-LPC.disable_s3=1',"
        "        '-global',  'driver=cfi.pflash01,property=secure,value=on',"
        "        '-drive',   'if=pflash,unit=0,file=$($EfiCode -replace '''',''''''),format=qcow2,readonly=on',"
        "        '-drive',   'if=pflash,unit=1,file=$($EfiVars -replace '''',''''''),format=qcow2',"
        "        '-drive',   'if=none,id=blk,file=$($VmImage   -replace '''','''''')',"
        "        '-device',  'virtio-blk-pci,drive=blk,bootindex=1',"
        "        '-netdev',  '$(
            $fwd = "user,id=net0,hostfwd=tcp::$AgentPort-:8080,hostfwd=tcp::$SshPort-:22"
            if ($ExtraPort -gt 0) { $fwd += ",hostfwd=tcp::$ExtraPort-:$ExtraPort" }
            $fwd
        )',"
        "        '-device',  'virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56',"
        "        '-object',  'rng-builtin,id=rng0',"
        "        '-device',  'virtio-rng-pci,rng=rng0',"
        "        '-display', 'none'"
        "    )"
    )
    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($AutostartScript, ($launcherLines -join "`r`n"), $Utf8NoBom)
    Write-Ok "Launcher written to $AutostartScript"

    $action   = New-ScheduledTaskAction `
        -Execute   "powershell.exe" `
        -Argument  "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$AutostartScript`""
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit  (New-TimeSpan -Hours 0) `
        -RestartCount        3 `
        -RestartInterval     (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action   $action `
        -Trigger  $trigger `
        -Settings $settings `
        -RunLevel Highest `
        -Force | Out-Null

    Write-Ok "Scheduled task '$TaskName' registered (triggers at system startup, runs with highest privilege)"
    $Results["Autostart task"] = "registered as '$TaskName'"
}


Write-Step "Step 5: Update hosts file"

$hostsEntry = "127.0.0.1`t$VmHostname"
$existing   = Select-String -Path $HostsFile `
    -Pattern ("\s" + [regex]::Escape($VmHostname) + "(\s|$)") `
    -ErrorAction SilentlyContinue

if ($existing) {
    Write-Skip "Entry for '$VmHostname' already exists: $($existing.Line.Trim())"
    $Results["Hosts entry"] = "already present"
} else {
    Add-Content -Path $HostsFile -Value "`r`n$hostsEntry" -Encoding ASCII
    Write-Ok "Added: $hostsEntry"
    $Results["Hosts entry"] = "added ($hostsEntry)"
}

# Summary report
$divider = "=" * 62
Write-Host "`n$divider" -ForegroundColor Cyan
Write-Host ("  {0,-22} {1}" -f "Component", "Result") -ForegroundColor Cyan
Write-Host $divider -ForegroundColor Cyan

foreach ($key in $Results.Keys) {
    $val = $Results[$key]
    $color = switch -Wildcard ($val) {
        "pending"       { "DarkGray" }
        "already*"      { "Yellow" }
        "skipped"       { "DarkGray" }
        "missing*"      { "Red" }
        "not found*"    { "Red" }
        "*FAIL*"        { "Red" }
        default         { "Green" }
    }
    Write-Host ("  {0,-22} {1}" -f $key, $val) -ForegroundColor $color
}

Write-Host $divider -ForegroundColor Cyan

$allFilesReady = (Test-Path $EfiCode) -and (Test-Path $EfiVars) -and (Test-Path $VmImage)

if ($allFilesReady) {
    Write-Host ""
    if (-not $NoAutostart) {
        Write-Host "VM will start automatically on next boot." -ForegroundColor Green
        Write-Host "To start it now (no reboot needed):" -ForegroundColor Cyan
        Write-Host "  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor White
        Write-Host ""
    }
    Write-Host "Once running, the agent is available at:" -ForegroundColor Cyan
    Write-Host "  http://${VmHostname}:${AgentPort}/" -ForegroundColor White
    Write-Host "  http://localhost:${AgentPort}/" -ForegroundColor White
    Write-Host ""
    Write-Host "SSH access:" -ForegroundColor Cyan
    Write-Host "  ssh -p $SshPort service@localhost" -ForegroundColor White
} else {
    Write-Host ""
    Write-Host "Image files are incomplete - resolve download issues before starting the VM." -ForegroundColor Red
}
