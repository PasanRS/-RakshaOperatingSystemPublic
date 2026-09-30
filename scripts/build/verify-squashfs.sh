#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-/home/ravan/raksha-build/iso/live/filesystem.squashfs}"
fail() { echo "[FAIL] squashfs: $*" >&2; exit 1; }
pass() { echo "[PASS] squashfs: $*"; }

test -f "${IMAGE}" || fail "image missing: ${IMAGE}"
unsquashfs -s "${IMAGE}" >/dev/null || fail "invalid superblock"

LIST=$(mktemp)
trap 'rm -f "${LIST}"' EXIT
unsquashfs -ll "${IMAGE}" >"${LIST}" 2>/dev/null

has_path() { grep -q "squashfs-root/$1\([[:space:]]\|$\)" "${LIST}"; }
cat_path() { unsquashfs -cat "${IMAGE}" "$1" 2>/dev/null; }

for path in \
  usr/bin/node \
  usr/bin/kwin_x11 \
  opt/ash-core/voice/server.py \
  opt/ash-core/voice/static/index.html \
  opt/ash-core/voice/venv/bin/python \
  opt/ash-core/gateways/whatsapp-gateway.js \
  opt/ash-core/gateways/node_modules/whatsapp-web.js/index.js \
  opt/ash-core/gateways/node_modules/qrcode-terminal/lib/main.js \
  usr/local/sbin/raksha-start-installer \
  usr/local/sbin/raksha-session \
  usr/bin/calamares \
  usr/sbin/grub-install \
  usr/sbin/grub-mkconfig \
  usr/sbin/grub-probe \
  usr/bin/efibootmgr \
  usr/lib/grub/x86_64-efi/modinfo.sh \
  usr/lib/grub/x86_64-efi/normal.mod \
  usr/lib/grub/x86_64-efi/linux.mod \
  etc/calamares/modules/bootloader.conf \
  etc/xdg/autostart/raksha-installer.desktop \
  etc/xdg/autostart/raksha-live-desktop.desktop \
  usr/share/applications/raksha-installer.desktop \
  usr/share/xsessions/raksha.desktop \
  usr/share/wallpapers/RakshaOS/contents/images/1920x1080.jpg; do
  has_path "${path}" || fail "missing ${path}"
done
pass "packaged executables and offline dependencies"

cat_path etc/raksha-iso-build | grep -qE '^RAKSHA_ISO_BUILD=[0-9]+([.][0-9]+)*$' || fail "invalid ISO build identity"
pass "ISO build identity"

cat_path usr/lib/os-release | grep -q '^PRETTY_NAME="Raksha OS 1.0.0"$' || fail "Raksha OS identity"
cat_path etc/xdg/kdeglobals | grep -q '^LookAndFeelPackage=org.raksha.desktop$' || fail "Raksha Plasma theme selection"
cat_path etc/xdg/kcm-about-distrorc | grep -q '/etc/calamares/branding/raksha/logo.png' || fail "About System logo"
cat_path usr/share/plasma/look-and-feel/org.raksha.desktop/contents/defaults | grep -q '^Theme=org.raksha.desktop$' || fail "Raksha Plasma splash"
if has_path usr/share/plasma/look-and-feel/org.debian.desktop; then
  fail "Debian Global Theme still exposed"
fi
if has_path usr/share/wallpapers/DebianTheme; then
  fail "Debian wallpaper still exposed"
fi
pass "managed Plasma X11 session and Raksha identity"

cat_path usr/share/plymouth/themes/raksha/raksha.plymouth | grep -q '^ModuleName=script$' || fail "unsupported Raksha Plymouth module"
has_path usr/lib/x86_64-linux-gnu/plymouth/script.so || fail "Plymouth script plugin missing"
has_path usr/share/plymouth/themes/raksha/animation-0027.png || fail "Raksha Plymouth frames incomplete"
pass "supported Raksha Plymouth animation"

cat_path etc/xdg/autostart/calamares-desktop-icon.desktop | grep -q '^Hidden=true$' || fail "Debian installer desktop icon enabled"
cat_path usr/share/applications/raksha-installer.desktop | grep -q 'Install Raksha OS' || fail "Raksha installer label"
cat_path usr/local/sbin/raksha-start-installer | grep -qF "grep -Fq 'raksha.install=1'" || fail "installer boot-mode gate"
pass "Raksha live desktop branding and installer split"

cat_path etc/calamares/modules/bootloader.conf | grep -q '^grubInstall: "/usr/sbin/grub-install"$' || fail "Calamares grub-install path"
cat_path etc/calamares/modules/bootloader.conf | grep -q '^grubMkconfig: "/usr/sbin/grub-mkconfig"$' || fail "Calamares grub-mkconfig path"
cat_path etc/calamares/modules/bootloader.conf | grep -q '^grubProbe: "/usr/sbin/grub-probe"$' || fail "Calamares grub-probe path"
cat_path etc/calamares/modules/bootloader.conf | grep -q '^efiBootMgr: "/usr/bin/efibootmgr"$' || fail "Calamares efibootmgr path"
cat_path etc/calamares/modules/bootloader.conf | grep -q '^efiBootloaderId: "Raksha_OS"$' || fail "Calamares EFI ID"
pass "Calamares target x86_64-efi GRUB runtime"

cat_path etc/systemd/system/ash-interface.service | grep -q 'ASH_VOICE_PORT=8888' || fail "interface port"
if grep -q 'squashfs-root/etc/systemd/system/.*/ash-voice.service' "${LIST}"; then
  fail "ash-voice enabled alongside ash-interface"
fi
grep -q 'squashfs-root/etc/systemd/system/.*/ash-interface.service' "${LIST}" || fail "ash-interface not enabled"
if ! cat_path etc/systemd/system/raksha-harness.service | grep -q '8890'; then
  cat_path opt/ash-core/harness/harness.py | grep -q '8890' || fail "Harness port"
fi
cat_path etc/systemd/system/raksha-dashboard.service | grep -q -- '--port 8889' || fail "Dashboard port"
cat_path etc/systemd/system/raksha-firstboot.service | grep -q 'ConditionPathExists=/var/lib/raksha/installed' || fail "firstboot installed condition"
cat_path etc/calamares/modules/shellprocess@raksha-post.conf | grep -q 'touch /var/lib/raksha/installed' || fail "Calamares marker hook"
if has_path var/lib/raksha/installed; then
  fail "live image contains installed-system marker"
fi
pass "installed-only firstboot and service ports"

cat_path etc/sddm.conf.d/autologin.conf | grep -q 'Session=raksha.desktop' || fail "Raksha X11 session"
cat_path usr/local/sbin/raksha-session | grep -q '/usr/bin/kwin_x11 --replace' || fail "installer KWin session"
cat_path usr/local/sbin/raksha-session | grep -q 'exec /usr/bin/startplasma-x11' || fail "live Plasma session"
cat_path usr/share/applications/raksha-installer.desktop | grep -q 'branding/raksha/logo.png' || fail "Raksha installer logo"
pass "dedicated graphical installer and live Plasma sessions"

echo "Squashfs verification complete."
