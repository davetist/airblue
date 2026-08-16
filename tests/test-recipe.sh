#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
recipe="$repo_root/recipes/recipe.yml"
packages="$repo_root/recipes/packages.yml"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_absent() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }
assert_panel_property() {
  local file="$1" panel="$2" property="$3" type="$4" value="$5"
  if ! python3 - "$file" "$panel" "$property" "$type" "$value" <<'PY'
import sys
import xml.etree.ElementTree as ET

file, panel, name, expected_type, expected_value = sys.argv[1:]
root = ET.parse(file).getroot()
node = root.find(
    f"./property[@name='panels']/property[@name='{panel}']/property[@name='{name}']"
)
if node is None:
    raise SystemExit(1)
if node.get("type") != expected_type or node.get("value") != expected_value:
    raise SystemExit(1)
PY
  then
    fail "$file $panel/$property is not $type:$value"
  fi
}

assert_contains "$recipe" 'name: airblue'
assert_contains "$recipe" 'base-image: ghcr.io/blue-build/base-images/fedora-base'
assert_contains "$recipe" 'image-version: 44'
assert_contains "$recipe" 'from-file: packages.yml'
assert_contains "$recipe" 'type: signing'

for package in lightdm lightdm-gtk xfce4-session xfce4-panel xfce4-settings xfconf xfwm4 xfdesktop thunar xfce4-terminal mousepad xarchiver xfce4-notifyd xfce4-power-manager NetworkManager-wifi NetworkManager-bluetooth network-manager-applet ModemManager xfce4-pulseaudio-plugin xfce4-whiskermenu-plugin xfce4-docklike-plugin xfce4-places-plugin xfce4-screenshooter-plugin xfce4-xkb-plugin pipewire pipewire-pulseaudio wireplumber upower bluez bluez-obexd cups flatpak podman distrobox fwupd linux-firmware mesa-dri-drivers libinput papirus-icon-theme gtk-murrine-engine sassc git-core; do
  assert_contains "$packages" "- $package"
done
for package in firefox firefox-langpacks toolbox; do
  assert_contains "$packages" "- $package"
done
assert_absent "$packages" 'gnome-shell'
assert_absent "$packages" '@xfce-desktop-environment'
assert_absent "$packages" '@xfce-desktop'
for package in nodejs yarnpkg python3-pip; do
  assert_absent "$packages" "- $package"
done
themes="$repo_root/files/scripts/install-themes.sh"
[[ -x "$themes" ]] || fail "$themes must exist and be executable"
[[ ! -e "$repo_root/scripts/install-themes.sh" ]] || \
  fail "$repo_root/scripts/install-themes.sh is obsolete; BlueBuild scripts belong under files/scripts"
assert_contains "$themes" 'ORCHIS_REPO=https://github.com/vinceliuice/Orchis-theme.git'
value="$(sed -n 's/^ORCHIS_COMMIT=//p' "$themes")"
[[ "$value" =~ ^[0-9a-f]{40}$ ]] || fail 'ORCHIS_COMMIT must be a full Git commit hash'
assert_contains "$themes" './install.sh --dest /usr/share/themes --theme default --color standard dark --size standard'
assert_contains "$themes" 'BIBATA_URL=https://github.com/ful1e5/Bibata_Cursor/releases/download/v2.0.7/Bibata-Modern-Classic.tar.xz'
assert_contains "$themes" 'BIBATA_SHA256=7d3495864e5bbef02f5e77de760b2905903b63c71495a78ef6306d19a3b556d8'
assert_contains "$themes" 'curl --fail --location --show-error --silent --retry 5 --retry-all-errors'
assert_contains "$themes" 'sha256sum --check -'
assert_contains "$themes" 'Bibata-Modern-Classic/index.theme'
for obsolete in BIBATA_REPO BIBATA_COMMIT 'yarn install' 'yarn generate'; do
  assert_absent "$themes" "$obsolete"
done
checksum_line="$(grep -nF 'sha256sum --check -' "$themes" | cut -d: -f1)"
extract_line="$(grep -nF 'tar --extract' "$themes" | cut -d: -f1)"
[[ -n "$checksum_line" && -n "$extract_line" && "$checksum_line" -lt "$extract_line" ]] || \
  fail 'Bibata checksum verification must occur before extraction'

xfce="$repo_root/files/system/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
assert_contains "$xfce/xsettings.xml" 'value="Orchis-Dark"'
assert_contains "$xfce/xsettings.xml" 'value="Papirus-Dark"'
assert_contains "$xfce/xsettings.xml" 'value="Bibata-Modern-Classic"'
assert_contains "$xfce/xfwm4.xml" 'value="Orchis-Dark"'
panel="$xfce/xfce4-panel.xml"
assert_panel_property "$panel" panel-1 length uint 100
assert_panel_property "$panel" panel-2 position string 'p=10;x=0;y=0'
assert_panel_property "$panel" panel-2 length uint 1
assert_panel_property "$panel" panel-2 length-adjust bool true
assert_panel_property "$panel" panel-2 autohide-behavior uint 2
assert_absent "$panel" 'name="pinned" type="array"'
docklike="$repo_root/files/system/etc/xdg/xfce4/panel/docklike.rc"
assert_contains "$docklike" '[user]'
assert_contains "$docklike" 'pinned=airblue-zen.desktop;airblue-bazaar.desktop;thunar.desktop;xfce4-terminal.desktop;'
assert_contains "$repo_root/files/system/usr/share/applications/airblue-zen.desktop" 'Exec=flatpak run app.zen_browser.zen %U'
assert_contains "$repo_root/files/system/usr/share/applications/defaults.list" 'x-scheme-handler/http=airblue-zen.desktop;'
assert_contains "$repo_root/files/system/usr/share/applications/defaults.list" 'x-scheme-handler/https=airblue-zen.desktop;'
assert_contains "$repo_root/files/system/usr/share/applications/defaults.list" 'text/html=airblue-zen.desktop;'
flatpaks="$repo_root/recipes/flatpaks.yml"
services="$repo_root/recipes/services.yml"
assert_contains "$flatpaks" 'scope: system'
assert_contains "$flatpaks" 'url: https://dl.flathub.org/repo/flathub.flatpakrepo'
assert_contains "$flatpaks" '- app.zen_browser.zen'
assert_contains "$flatpaks" '- io.github.kolunmi.Bazaar'
assert_contains "$flatpaks" 'scope: user'
assert_contains "$services" '- lightdm.service'
assert_contains "$services" '- cups.socket'
assert_contains "$services" '- ModemManager.service'
assert_absent "$services" 'masked:'
image_test="$repo_root/tests/test-image.sh"
image_validator="$repo_root/tests/test-image-validator.sh"
assert_contains "$image_test" 'image smoke test: PASS'
assert_contains "$image_test" 'modinfo -k "$version" "$module"'
assert_contains "$image_test" '--validate-config'
assert_contains "$image_validator" 'image validator fixtures: PASS'

readme="$repo_root/README.md"
assert_contains "$readme" 'IMAGE=ghcr.io/OWNER/airblue'
assert_contains "$readme" 'ostree-unverified-registry:$IMAGE:latest'
assert_contains "$readme" 'ostree-image-signed:docker://$IMAGE:latest'
assert_contains "$readme" 'rpm-ostree status'
assert_contains "$readme" 'rpm-ostree rollback'
assert_contains "$readme" 'rpm-ostree upgrade'
assert_contains "$readme" 'flatpak update'
assert_contains "$readme" 'cosign verify --key cosign.pub'
for heading in \
  '1. LightDM/existing-user XFCE login' \
  '2. Wi-Fi reboot and suspend transfer' \
  '3. Bluetooth discovery/connect' \
  '4. FaceTime HD camera in a Flatpak' \
  '5. Speaker/headphone/microphone audio' \
  '6. Brightness/keyboard/trackpad/battery' \
  '7. Suspend/resume with input/network/display' \
  '8. Zen HTTP/HTTPS defaults' \
  '9. Bazaar install/remove from Flathub' \
  '10. Distrobox create/enter/remove with Podman'; do
  assert_contains "$readme" "$heading"
done
bash "$repo_root/tests/test-readme.sh"
bash "$repo_root/tests/test-readme-validator.sh"
bash "$repo_root/tests/test-image-validator.sh"

python3 "$repo_root/tests/test-workflow.py"
bash "$repo_root/tests/test-workflow-validator.sh"
printf 'recipe contract: PASS\n'
