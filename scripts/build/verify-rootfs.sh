#!/usr/bin/env bash
set -euo pipefail

R="${1:-/home/ravan/raksha-build/rootfs}"
fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

test -d "${R}" || fail "rootfs not found: ${R}"

test -f "${R}/etc/raksha-iso-build" || fail "ISO build identity missing"
grep -qE '^RAKSHA_ISO_BUILD=[0-9]+([.][0-9]+)*$' "${R}/etc/raksha-iso-build" || fail "unexpected ISO build identity"

test -x "${R}/usr/bin/kwin_x11" || fail "kwin_x11 missing; Plasma X11 windows will be unmanaged"
test -L "${R}/etc/os-release" || fail "/etc/os-release must link to canonical identity"
test "$(readlink "${R}/etc/os-release")" = ../usr/lib/os-release || fail "broken os-release link"
grep -q '^PRETTY_NAME="Raksha OS 1.0.0"$' "${R}/usr/lib/os-release" || fail "Raksha OS identity"
grep -q '^LookAndFeelPackage=org.raksha.desktop$' "${R}/etc/xdg/kdeglobals" || fail "Raksha Plasma look-and-feel not selected"
grep -q '^LogoPath=/etc/calamares/branding/raksha/logo.png$' "${R}/etc/xdg/kcm-about-distrorc" || fail "About System uses non-Raksha logo"
grep -q '^Theme=org.raksha.desktop$' "${R}/usr/share/plasma/look-and-feel/org.raksha.desktop/contents/defaults" || fail "Raksha Plasma splash not selected"
test -f "${R}/usr/share/plasma/look-and-feel/org.raksha.desktop/contents/splash/Splash.qml" || fail "Raksha Plasma splash missing"
test ! -e "${R}/usr/share/plasma/look-and-feel/org.debian.desktop" || fail "Debian Global Theme still exposed"
test ! -e "${R}/usr/share/wallpapers/DebianTheme" || fail "Debian wallpaper still exposed"
pass "managed Plasma X11 session and Raksha desktop identity"

grep -q '^ModuleName=script$' "${R}/usr/share/plymouth/themes/raksha/raksha.plymouth" || fail "unsupported Raksha Plymouth module"
test -f "${R}/usr/lib/x86_64-linux-gnu/plymouth/script.so" || fail "Plymouth script plugin missing"
test -f "${R}/usr/share/plymouth/themes/raksha/animation-0027.png" || fail "Raksha Plymouth frames incomplete"
pass "supported Raksha Plymouth animation"

VOICE_UNIT="${R}/etc/systemd/system/ash-voice.service"
INTERFACE_UNIT="${R}/etc/systemd/system/ash-interface.service"
WHATSAPP_UNIT="${R}/etc/systemd/system/ash-whatsapp.service"
FIRSTBOOT_UNIT="${R}/etc/systemd/system/raksha-firstboot.service"

grep -q '^ExecStart=/opt/ash-core/voice/venv/bin/python /opt/ash-core/voice/server.py$' "${VOICE_UNIT}" || fail "ash-voice ExecStart"
grep -q '^ExecStart=/opt/ash-core/voice/venv/bin/python /opt/ash-core/voice/server.py$' "${INTERFACE_UNIT}" || fail "ash-interface ExecStart"
test -f "${R}/opt/ash-core/voice/static/index.html" || fail "voice interface UI assets"
if find "${R}/etc/systemd/system" -type l -name ash-voice.service -print -quit | grep -q .; then
  fail "ash-voice and ash-interface would compete for port 8888"
fi
find "${R}/etc/systemd/system" -type l -name ash-interface.service -print -quit | grep -q . || fail "ash-interface not enabled"
pass "voice units use packaged runtime"

test "$(readlink "${R}/opt/ash-core/voice/venv/bin/python")" = python3 || fail "voice venv python link"
test "$(readlink "${R}/opt/ash-core/voice/venv/bin/python3")" = /usr/bin/python3 || fail "voice venv python3 link"
test -x "${R}/usr/bin/python3" || fail "rootfs Python interpreter"
pass "voice venv interpreter chain"

test -x "${R}/usr/bin/node" || fail "Node.js binary missing"
grep -q '^ExecStart=/usr/bin/node /opt/ash-core/gateways/whatsapp-gateway.js$' "${WHATSAPP_UNIT}" || fail "WhatsApp ExecStart"
test -f "${R}/opt/ash-core/gateways/node_modules/whatsapp-web.js/index.js" || fail "whatsapp-web.js missing"
test -f "${R}/opt/ash-core/gateways/node_modules/qrcode-terminal/lib/main.js" || fail "qrcode-terminal missing"
test -f "${R}/opt/ash-core/gateways/ash-whatsapp-bridge/node_modules/@whiskeysockets/baileys/package.json" || fail "Baileys bridge dependencies missing"
pass "offline WhatsApp runtime"

grep -q '^ConditionPathExists=/var/lib/raksha/installed$' "${FIRSTBOOT_UNIT}" || fail "firstboot installed marker condition"
grep -q '^ConditionPathExists=!/var/lib/raksha/.first-boot-done$' "${FIRSTBOOT_UNIT}" || fail "firstboot completion condition"
test ! -e "${R}/var/lib/raksha/installed" || fail "installed marker must not exist in live rootfs"
grep -q 'touch /var/lib/raksha/installed' "${R}/etc/calamares/modules/shellprocess@raksha-post.conf" || fail "Calamares installed marker"
grep -q 'touch "${STAMP}"' "${R}/usr/local/bin/raksha-firstboot" || fail "firstboot completion write"
if grep -qE 'chown -R[^\n]*(/opt/ash-core|/opt/raksha-dashboard)' "${R}/usr/local/bin/raksha-firstboot"; then
  fail "firstboot recursively owns immutable runtime"
fi
pass "installed-only one-shot firstboot"

test -x "${R}/usr/local/sbin/raksha-start-installer" || fail "Calamares launcher"
grep -q 'Exec=/usr/local/sbin/raksha-start-installer --auto' "${R}/etc/xdg/autostart/raksha-installer.desktop" || fail "Calamares autostart"
grep -q 'Exec=/usr/local/sbin/raksha-start-installer --launch' "${R}/usr/share/applications/raksha-installer.desktop" || fail "Raksha installer desktop launcher"
grep -q '^Hidden=true$' "${R}/etc/xdg/autostart/calamares-desktop-icon.desktop" || fail "Debian installer icon autostart enabled"
grep -qF "grep -Fq 'raksha.install=1'" "${R}/usr/local/sbin/raksha-start-installer" || fail "installer boot-mode gate"
test -x "${R}/usr/bin/calamares" || fail "Calamares executable"
test -f "${R}/usr/share/wallpapers/RakshaOS/contents/images/1920x1080.jpg" || fail "Raksha Plasma wallpaper"
pass "Raksha Calamares launch path and live desktop branding"

BOOTLOADER_CONF="${R}/etc/calamares/modules/bootloader.conf"
test -x "${R}/usr/sbin/grub-install" || fail "target grub-install missing"
test -x "${R}/usr/sbin/grub-mkconfig" || fail "target grub-mkconfig missing"
test -x "${R}/usr/sbin/grub-probe" || fail "target grub-probe missing"
test -x "${R}/usr/bin/efibootmgr" || fail "target efibootmgr missing"
test -f "${R}/usr/lib/grub/x86_64-efi/modinfo.sh" || fail "x86_64-efi GRUB platform metadata missing"
test -f "${R}/usr/lib/grub/x86_64-efi/normal.mod" || fail "x86_64-efi normal module missing"
test -f "${R}/usr/lib/grub/x86_64-efi/linux.mod" || fail "x86_64-efi linux module missing"
grep -q '^grubInstall: "/usr/sbin/grub-install"$' "${BOOTLOADER_CONF}" || fail "Calamares grub-install target path"
grep -q '^grubMkconfig: "/usr/sbin/grub-mkconfig"$' "${BOOTLOADER_CONF}" || fail "Calamares grub-mkconfig target path"
grep -q '^grubProbe: "/usr/sbin/grub-probe"$' "${BOOTLOADER_CONF}" || fail "Calamares grub-probe target path"
grep -q '^efiBootMgr: "/usr/bin/efibootmgr"$' "${BOOTLOADER_CONF}" || fail "Calamares efibootmgr target path"
grep -q '^efiBootloaderId: "Raksha_OS"$' "${BOOTLOADER_CONF}" || fail "Calamares EFI bootloader ID"
for package in grub-common grub2-common grub-efi-amd64 grub-efi-amd64-bin efibootmgr; do
  dpkg-query --admindir="${R}/var/lib/dpkg" -W -f='${db:Status-Abbrev}\n' "${package}" 2>/dev/null | \
    grep -q '^ii ' || fail "target package not installed: ${package}"
done
pass "Calamares target x86_64-efi GRUB runtime"

grep -q 'ASH_VOICE_PORT=8888' "${INTERFACE_UNIT}" || fail "interface port 8888"
grep -q -- '--port 8890' "${R}/etc/systemd/system/raksha-harness.service" || grep -q '8890' "${R}/opt/ash-core/harness/harness.py" || fail "Harness port 8890"
grep -q -- '--port 8889' "${R}/etc/systemd/system/raksha-dashboard.service" || fail "Dashboard port 8889"
pass "service ports 8888/8889/8890"

grep -q '^Session=raksha.desktop$' "${R}/etc/sddm.conf.d/autologin.conf" || fail "SDDM Raksha session"
test -f "${R}/usr/share/xsessions/plasmax11.desktop" || fail "Plasma X11 session file"
test -x "${R}/usr/local/sbin/raksha-session" || fail "Raksha session dispatcher"
test -f "${R}/usr/share/xsessions/raksha.desktop" || fail "Raksha X11 session file"
test -x "${R}/usr/bin/xhost" || fail "installer X11 access helper"
test -x "${R}/usr/bin/xsetroot" || fail "installer session background helper"
grep -q 'ravan.*NOPASSWD:ALL' "${R}/etc/sudoers.d/ravan" || fail "installer session requires live sudo policy"
grep -qF "grep -Fq 'raksha.install=1'" "${R}/usr/local/sbin/raksha-session" || fail "installer session boot-mode gate"
grep -q 'exec /usr/bin/startplasma-x11' "${R}/usr/local/sbin/raksha-session" || fail "Try mode Plasma session"
grep -q '/usr/bin/kwin_x11 --replace' "${R}/usr/local/sbin/raksha-session" || fail "installer window manager"
grep -q 'sudo -n env' "${R}/usr/local/sbin/raksha-session" || fail "direct Calamares installer session"
grep -q '^Icon=/etc/calamares/branding/raksha/logo.png$' "${R}/usr/share/applications/raksha-installer.desktop" || fail "Raksha installer icon"
test -e "${R}/etc/systemd/system/display-manager.service" || fail "display-manager service link"
if ! find "${R}/lib/modules" -type f \
    \( -name 'nvidia.ko*' -o -name 'nvidia-current.ko*' \) -print -quit | grep -q .; then
  test ! -e "${R}/etc/modules-load.d/nvidia.conf" || fail "stale forced nvidia module load"
  test ! -e "${R}/etc/modprobe.d/nvidia-blacklists-nouveau.conf" || fail "nouveau blacklisted without NVIDIA module"
  test ! -e "${R}/etc/modprobe.d/nvidia.conf" || fail "stale NVIDIA modprobe aliases"
  if find "${R}/etc/systemd/system" -type l -name nvidia-persistenced.service -print -quit | grep -q .; then
    fail "NVIDIA persistence enabled without NVIDIA kernel module"
  fi
fi
pass "dedicated installer / Plasma live sessions and portable graphics policy"

echo "Rootfs verification complete."
