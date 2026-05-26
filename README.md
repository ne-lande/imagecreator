## ImageCreator

Builds and launches a Flatcar Linux QEMU VM pre-configured to run the CrudeAgent container on boot. The VM pulls the agent image from a local Docker registry.

> **Platform support:** full scripts are provided for both **Linux** (`setup.sh` / `download.sh`) and **Windows** (`setup.ps1` / `download.ps1`). Jump to the relevant section below.

---

## Linux

### Architecture (Linux — TAP/bridge)

```
┌─────────────────────────────────────────────────┐
│  Host                                           │
│                                                 │
│  ┌──────────────┐    ┌───────────────────────┐  │
│  │ Docker        │    │ QEMU VM (Flatcar)     │  │
│  │ Registry :5000│◄───│  192.168.100.10       │  │
│  └──────────────┘    │                       │  │
│        ▲              │  ┌─────────────────┐  │  │
│        │              │  │ crudeagent:latest│  │  │
│  192.168.100.1        │  │ (port 8080)     │  │  │
│  crudeagent-br        │  └─────────────────┘  │  │
│        │              └───────────────────────┘  │
│  crudeagent-tap                                  │
└─────────────────────────────────────────────────┘
```

### Prerequisites (Linux)

- QEMU (`qemu-system-x86_64`)
- [Butane](https://coreos.github.io/butane/) (Flatcar config transpiler)
- Docker (for building the agent image and running the local registry)
- KVM support (`/dev/kvm`) for hardware acceleration
- Root/sudo access (for bridge and TAP device creation)

A Nix flake is provided for convenience:

```bash
nix develop   # drops you into a shell with qemu, butane, libguestfs
```

### Quick Start (Linux)

**1. Download Flatcar artifacts**

```bash
cd imagecreator
bash download.sh
```

**2. Run the setup script**

```bash
bash setup.sh
```

`setup.sh` performs the following steps:

1. **Generate SSH keys** for `nobody` and `service` users (stored in `.ssh/`)
2. **Build** the CrudeAgent native image via `crudeagent/native.Dockerfile`
3. **Start** a local Docker registry on port `5000`
4. **Tag & push** the agent image to `localhost:5000/crudeagent:latest`
5. **Render** `config.yaml` with the generated SSH public keys and **transpile** to `config.ign` using Butane
6. **Create** a Linux bridge (`crudeagent-br` at `192.168.100.1/24`) and TAP device (`crudeagent-tap`)
7. **Enable** IP forwarding and NAT so the VM can reach the registry
8. **Launch** the QEMU VM with the Ignition config and TAP networking

**3. Access the agent (Linux)**

Once the VM boots (typically 30–60 seconds), the CrudeAgent API is available at:

```
http://192.168.100.10:8080/
```

**4. SSH into the VM (Linux)**

```bash
# Service account (docker + sudo access)
ssh -i .ssh/service_ed25519 service@192.168.100.10
```

---

## Windows

### Architecture (Windows — QEMU SLIRP user-mode networking)

On Windows, TAP/bridge devices are not available without third-party drivers.
`setup.ps1` uses QEMU's built-in **user-mode (SLIRP) networking** instead.
The VM's ports are forwarded to `localhost` on the host:

```
┌──────────────────────────────────────────────────────┐
│  Host (Windows)                                      │
│                                                      │
│  ┌──────────────┐    ┌────────────────────────────┐  │
│  │ Docker        │    │ QEMU VM (Flatcar)          │  │
│  │ Registry :5000│◄───│  10.0.2.15 (DHCP/SLIRP)   │  │
│  └──────────────┘    │                            │  │
│        ▲              │  ┌──────────────────────┐  │  │
│  localhost:5000       │  │ crudeagent:latest     │  │  │
│  (10.0.2.2 in VM)     │  │ (port 8080)          │  │  │
│                       │  └──────────────────────┘  │  │
│  localhost:8080 ◄─────┤  port-forwarded to host    │  │
│  localhost:2222 ◄─────┤  SSH port-forwarded        │  │
│                       └────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

### Prerequisites (Windows)

| Requirement | Notes |
|-------------|-------|
| **Windows 10 / 11** (64-bit) | |
| **QEMU for Windows** | Download from <https://www.qemu.org/download/#windows>; add the install directory to `PATH` |
| **Docker Desktop** | <https://www.docker.com/products/docker-desktop/> |
| **OpenSSH Client** | Included in Windows 10 1809+; enable via *Settings → Apps → Optional Features* |
| **PowerShell 5.1+** | Included in Windows 10+; PowerShell 7 also works |
| **Butane** (optional) | `setup.ps1` downloads `butane.exe` automatically if not found in `PATH` |
| **WHPX** (optional) | Enable *Windows Hypervisor Platform* in *Windows Features* for near-native VM speed |

> **No admin rights required** — SLIRP networking runs entirely in user space.

### Quick Start (Windows)

Open **PowerShell** (no elevation needed) and run:

**1. Download Flatcar artifacts**

```powershell
cd imagecreator
.\download.ps1
```

This fetches from `https://stable.release.flatcar-linux.net/amd64-usr/current/`:
- `flatcar_production_qemu_uefi_image.img`
- `flatcar_production_qemu_uefi_efi_code.qcow2`
- `flatcar_production_qemu_uefi_efi_vars.qcow2`
- `flatcar_production_qemu_uefi.sh`

If PowerShell blocks script execution, run once:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**2. Run the setup script**

```powershell
.\setup.ps1
```

`setup.ps1` performs the following steps:

1. **Generate SSH keys** for the `service` user (stored in `.ssh/`)
2. **Build** the CrudeAgent native image via `crudeagent/native.Dockerfile`
3. **Start** a local Docker registry on port `5000`
4. **Tag & push** the agent image to `localhost:5000/crudeagent:latest`
5. **Download `butane.exe`** (if not already in `PATH`) and **transpile** `config.yaml` → `config.ign`
6. **Reset** the VM image and EFI vars to pristine state (forces Ignition provisioning)
7. **Launch** the QEMU VM with SLIRP networking and port forwards

Optional parameters:

```powershell
.\setup.ps1 -SkipBuild      # skip Docker image build
.\setup.ps1 -SkipRegistry   # skip starting the registry
.\setup.ps1 -SshPort 2222   # change SSH forward port (default 2222)
.\setup.ps1 -AgentPort 8080 # change agent forward port (default 8080)
.\setup.ps1 -Memory 4096    # set VM RAM in MB (default 2048)
```

**3. Access the agent (Windows)**

Once the VM boots (typically 60–120 seconds on TCG, 30–60 s with WHPX):

```
http://localhost:8080/
```

**4. SSH into the VM (Windows)**

```powershell
# Service account (docker + sudo access)
ssh -i .ssh\service_ed25519 -p 2222 service@localhost
```

### Windows — Networking Notes

| Item | Linux (TAP) | Windows (SLIRP) |
|------|-------------|-----------------|
| VM IP | `192.168.100.10` (static) | `10.0.2.15` (DHCP) |
| Host IP from VM | `192.168.100.1` | `10.0.2.2` |
| Docker registry URL (in VM) | `192.168.100.1:5000` | `10.0.2.2:5000` |
| Agent URL (from host) | `http://192.168.100.10:8080/` | `http://localhost:8080/` |
| SSH (from host) | `ssh service@192.168.100.10` | `ssh -p 2222 service@localhost` |
| Admin rights needed | Yes (bridge/TAP) | No |

`setup.ps1` automatically rewrites `192.168.100.1` → `10.0.2.2` in the rendered Butane config so the VM's `agent.service` and Docker daemon point at the correct registry address.

### Windows — Accelerator Notes

QEMU tries accelerators in order: **WHPX → TCG**.

- **WHPX** (Windows Hypervisor Platform): near-native speed. Enable in *Windows Features → Windows Hypervisor Platform*, then reboot.
- **TCG** (software emulation): always available, but significantly slower (expect 3–5× longer boot time).

Hyper-V and WHPX can coexist; you do **not** need to disable Hyper-V.

---

### Security Features

#### Full Disk Encryption (LUKS)

The root partition is encrypted with LUKS via Flatcar's Ignition support. The encryption key is embedded in the Ignition config and applied automatically during first boot — no manual passphrase entry required.

- **Device:** `/dev/disk/by-partlabel/ROOT`
- **LUKS name:** `rootencrypted`
- **Filesystem:** ext4 on `/dev/mapper/rootencrypted`

#### SSH Hardening

All password-based authentication is disabled:

- `PasswordAuthentication no`
- `KbdInteractiveAuthentication no`
- `ChallengeResponseAuthentication no`
- `UsePAM no`
- `PermitRootLogin no`

Only public key authentication is allowed (`AuthenticationMethods publickey`).

#### SSH Users

| User | Purpose | Shell | Groups | Capabilities |
|------|---------|-------|--------|-------------|
| `nobody` | Debugging / read-only inspection | `/bin/sh` | `nogroup` | Restricted — no TCP forwarding, forced `/bin/sh` |
| `service` | Configuration and task management | `/bin/bash` | `docker`, `sudo` | Can run `docker` and `systemctl` via sudo (NOPASSWD) |

SSH keypairs are auto-generated by `setup.sh` into the `.ssh/` directory on first run and injected into the Butane config before transpilation.

### VM Configuration (config.yaml)

The Butane config provisions the Flatcar VM with:

- **LUKS encryption** — root partition encrypted with an embedded key
- **Docker daemon** — configured with `192.168.100.1:5000` as an insecure registry
- **SSH hardening** — all password auth disabled, root login disabled, key-only access
- **Static networking** — `192.168.100.10/24` via the TAP interface (MAC `52:54:00:12:34:56`)
- **`nobody` user** — minimal debugging account with restricted shell
- **`service` user** — operational account with docker/sudo access
- **`agent.service`** — a systemd unit that pulls and runs `192.168.100.1:5000/crudeagent:latest` on boot, with automatic restart

### Network Layout

| Component | Address |
|-----------|---------|
| Host bridge (`crudeagent-br`) | `192.168.100.1/24` |
| VM (`eth0` via TAP) | `192.168.100.10/24` |
| Docker registry | `192.168.100.1:5000` |
| CrudeAgent (inside VM) | `192.168.100.10:8080` |

### Cleanup

The `setup.sh` script registers a cleanup trap that removes the TAP and bridge devices on exit. To manually clean up:

```bash
sudo ip link delete crudeagent-tap 2>/dev/null
sudo ip link delete crudeagent-br 2>/dev/null
docker rm -f registry
```
