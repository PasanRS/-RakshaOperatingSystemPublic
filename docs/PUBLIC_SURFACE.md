# Public distribution boundary

This repository is intentionally a distribution and build surface, not a mirror of the private Raksha OS Core environment.

## Safe to publish

- Generic source code, build scripts, service templates, branding, and documentation.
- Placeholder configuration with no credentials or personal data.
- Reproducible release metadata, checksums, and hardware-test notes.

## Keep private

- Ash identity, memory, soul, session databases, chat exports, and logs.
- WhatsApp, Telegram, voice, browser, SSH, cloud, and gateway sessions.
- API keys, bearer tokens, cookies, private certificates, and machine-specific paths.
- Proprietary model weights and local device inventories unless explicitly cleared.

Before every public release, scan the tree for secrets and inspect generated ISO contents. A successful Git push is not evidence that a release is safe or bootable.
