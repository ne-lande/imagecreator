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
5. **Download `butane.exe`** (if not already in `PATH`) and **transpile** `config.windows.yaml` → `config.ign`
6. **Reset** the VM image and EFI vars to pristine state (forces Ignition provisioning)
7. **Launch** the QEMU VM with SLIRP networking and port forwards

Optional parameters:

```powershell
# Agent image lifecycle:
.\setup.ps1 -SkipBuild      # skip Docker image build (reuse existing local image)
.\setup.ps1 -SkipPush       # skip tagging and pushing to the registry
.\setup.ps1 -SkipAgent      # skip both build AND push (image already in registry)

.\setup.ps1 -SkipRegistry   # skip starting the local registry (ignored for Docker Hub)
.\setup.ps1 -SshPort 2222   # change SSH forward port (default 2222)
.\setup.ps1 -AgentPort 8080 # change agent forward port (default 8080)
.\setup.ps1 -Memory 4096    # set VM RAM in MB (default 2048)
.\setup.ps1 -NoDisplay      # headless / serial-console only (no SDL window)
.\setup.ps1 -UseWhpx        # enable WHPX acceleration (see accelerator notes below)

# Registry selection (default: Docker Hub):
.\setup.ps1 -Registry docker.io -DockerHubUser myuser   # push/pull via Docker Hub (default)
.\setup.ps1 -Registry 192.168.1.5:5000                  # use a custom/private registry
.\setup.ps1 -Registry localhost:5000                     # use a local registry already running

# Forward extra ports to reach containers running inside the VM:
.\setup.ps1 -ForwardPorts "3000:3000"
.\setup.ps1 -ForwardPorts "3000:3000,5432:5432,6379:6379"
.\setup.ps1 -ForwardPorts @("3000:3000", "5432:5432")
```

Each `-ForwardPorts` entry is `hostPort:guestPort` (TCP).
The default SSH (`2222:22`) and agent (`8080:8080`) forwards are always included.

#### Registry modes

| Mode | Flag | Behaviour |
|------|------|-----------|
| **Docker Hub** (default) | `-Registry docker.io -DockerHubUser <user>` | Image pushed to `<user>/crudeagent:latest` on Docker Hub; VM pulls from there over the internet. No local registry container is started. If `-DockerHubUser` is omitted, the logged-in Docker Hub username is detected automatically. |
| **Custom / private** | `-Registry host:port` | A local `registry:2` container is started on `localhost:<RegistryPort>`; the VM pulls from `10.0.2.2:<port>` via SLIRP. |

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

### Windows - Accelerator Notes

By default `setup.ps1` uses **TCG** (software emulation) only, which always
works without any configuration and produces no warning messages.

To enable **WHPX** (Windows Hypervisor Platform) for near-native speed:

1. Open *Windows Features* and tick **Windows Hypervisor Platform**, then reboot.
2. Pass `-UseWhpx` to `setup.ps1`:

```powershell
.\setup.ps1 -UseWhpx
```

QEMU will then try WHPX first and fall back to TCG automatically if unavailable.

| Accelerator | Speed | Requirement | How to enable |
|-------------|-------|-------------|---------------|
| **TCG** (default) | ~3-5x slower than native | None | Always available |
| **WHPX** | Near-native | Windows Hypervisor Platform feature | `-UseWhpx` flag |

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

### VM Configuration (config.yaml / config.windows.yaml)

Two Butane configs are provided:

| File | Platform | Networking |
|------|----------|------------|
| `config.yaml` | Linux (`setup.sh`) | Static IP `192.168.100.10/24` via TAP bridge |
| `config.windows.yaml` | Windows (`setup.ps1`) | DHCP via QEMU SLIRP (`10.0.2.15`), DNS `10.0.2.3` |

Both configs provision the Flatcar VM with:

- **LUKS encryption** — root partition encrypted with an embedded key
- **Docker daemon** — configured with the registry address as an insecure registry
- **SSH hardening** — all password auth disabled, root login disabled, key-only access
- **`service` user** — operational account with docker/sudo access
- **`agent.service`** — a systemd unit that pulls and runs the agent image on boot, with automatic restart

`config.windows.yaml` additionally sets `After=network-online.target` on `agent.service` so Docker does not start before DHCP completes.

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
