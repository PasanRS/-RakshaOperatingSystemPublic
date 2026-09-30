# Changelog

Public-facing release notes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Core implementation sync — 2026-10-01

The private Raksha OS Core has advanced beyond v1.0.4 with the following work now present in the system tree. This note is additive; the private core remains the authoritative source and this public port still requires review before release:

- Added a canonical Raksha configuration with validation, deterministic runtime rendering, and bootstrap tooling.
- Added Ash native authority execution, durable task-worker services, task routing, and a Raksha-wide systemd target.
- Expanded heartbeat, harness, interface, memory, and Cortex integration so live actions can return structured runtime evidence.
- Added out-of-band defibrillator/sentry recovery paths with explicit configuration gates.
- Added Debian-stratum v5.2 repair, rebuild, rootfs, squashfs, and installer verification tooling.
- Added credential-free Codex handoff, startup, and portability scripts for continuing Raksha work across machines.
- Added the generated Fastfetch schema snapshot used by the system inventory surface.
- Added a read-only initramfs preflight script, periodic timer, and final reboot/halt hook to catch missing or unreadable initramfs files before the next boot.

These changes are not claimed as a public release yet. They need a sanitized public port, validation on the target installation, and release evidence before being attached to an ISO.

### Added

- Public distribution staging repository for Raksha OS.
- Dependency-free landing page and public-surface policy.
- Separation between public build source and private Raksha OS Core state.

### Planned

- Reproducible ISO build verification in CI.
- Signed GitHub Release artifacts with SHA-256 checksums.
- Hardware compatibility notes for live boot and installation.

## [1.0.4] - 2026-07-24

### Added

- Ash live tool interface and deterministic runtime inventory paths in the private core line.
- Public documentation boundary for the distribution build.

## [1.0.0] - 2026-07-18

### Added

- First recorded Raksha OS bootable and installable release.
- Custom GRUB, Plymouth, SDDM, and Calamares branding.
- Debian 13 desktop base with Ash service orchestration.

> Future public ISO releases will include fresh build logs, checksums, and test evidence.
