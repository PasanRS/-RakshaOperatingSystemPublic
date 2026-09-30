#!/usr/bin/env bash
set -euo pipefail

REPO=/home/ravan/Raksha-OS-Core
ISO_WORK=/home/ravan/raksha-build/iso
OUTPUT="${REPO}/builds/raksha-os-v5.2-amd64.iso"
SQUASHFS="${ISO_WORK}/live/filesystem.squashfs"

[[ $(id -u) -eq 0 ]] || { echo "Run as root: sudo bash $0" >&2; exit 1; }
[[ -f "${ISO_WORK}/boot/vmlinuz" ]] || { echo "Missing ISO kernel" >&2; exit 1; }
[[ -f "${ISO_WORK}/boot/initrd" ]] || { echo "Missing ISO initrd" >&2; exit 1; }

"${REPO}/scripts/build/verify-squashfs.sh" "${SQUASHFS}"

XWRAP=$(mktemp /tmp/xr-raksha-v5.2.XXXXXX)
cleanup() { rm -f "${XWRAP}"; }
trap cleanup EXIT
cat >"${XWRAP}" <<'EOF'
#!/usr/bin/env bash
ARGS=()
for arg in "$@"; do
  ARGS+=("${arg}")
  [[ "${arg}" == mkisofs ]] && ARGS+=(-iso-level 3)
done
exec /usr/bin/xorriso "${ARGS[@]}"
EOF
chmod 0755 "${XWRAP}"

mkdir -p "$(dirname "${OUTPUT}")"
rm -f "${OUTPUT}"
grub-mkrescue --xorriso="${XWRAP}" -o "${OUTPUT}" "${ISO_WORK}"

file "${OUTPUT}"
sha256sum "${OUTPUT}"
echo "RAKSHA OS ISO v5.2 ASSEMBLY COMPLETE: ${OUTPUT}"
