<div align="center">

# RAKSHA OS

### A sovereign, AI-native Linux operating system.

Boot the system. Keep your context. Build with intent.

[![Build](https://img.shields.io/badge/build-source--available-8ff0c8?style=flat-square)](scripts/build/)
[![Base](https://img.shields.io/badge/base-Debian%2013%20%2B%20Bedrock-9b8cff?style=flat-square)](docs/)
[![Status](https://img.shields.io/badge/status-public%20preview-ffb86b?style=flat-square)](CHANGELOG.md)

<a href="docs/index.html">Open the Raksha landing page →</a>

</div>

---

Raksha OS is a branded Debian 13 desktop base with Bedrock Linux integration, KDE Plasma, a native Ash runtime, and a reproducible path toward bootable live media and installation.

This is the public distribution surface. Private identity, memory, session data, credentials, personal integrations, and machine-specific state remain in the private Raksha OS Core repository.

## Quick start

Build on a Debian-compatible host with root access, network access, and roughly 25 GB of free disk space:

```bash
git clone https://github.com/PasanRS/Raksha-OS-Public.git
cd Raksha-OS-Public
sudo bash scripts/build/build-iso-v2.sh
```

Generated media is written under `builds/`. Inspect the builder and verify devices with `lsblk` before writing any USB.

## Included

- Raksha branding: boot visuals, login theme, wallpapers, and OS identity.
- Debian 13 + Bedrock-oriented build and filesystem overlay.
- Ash core, heartbeat, memory, dreaming, and watchdog service templates.
- KDE Plasma desktop and Calamares-oriented live installation path.
- Dashboard, terminal tooling, and a dependency-free project landing page.

## Architecture

```text
hardware → Debian 13 + Bedrock → KDE Plasma + systemd
                                  ↓
                 Ash: core · memory · heartbeat · dreaming · watchdog
                                  ↓
                       local tools, dashboard, release channels
```

## Releases and ISO downloads

This repository currently tracks the public build source. A downloadable ISO should be published through a GitHub Release only after a clean build, boot test, installer test, and SHA-256 checksum are recorded. Until then, a source checkout is not a signed or validated installer image.

See [CHANGELOG.md](CHANGELOG.md), [the build notes](docs/ISO_PACKAGE_MANIFEST.md), and [the public-surface policy](docs/PUBLIC_SURFACE.md).

## Contributing

Keep changes reproducible and free of private runtime state. Do not commit tokens, chat exports, personal memory, model weights, messaging sessions, SSH material, or machine-specific logs.

## License and status

Raksha OS is an evolving public preview. Licensing terms for upstream components remain governed by their respective licenses; see `LICENSE` when the distribution license is finalized.
