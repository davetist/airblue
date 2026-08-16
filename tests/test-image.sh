#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_rpm() {
  rpm -q "$1" >/dev/null 2>&1 || fail "required RPM is not installed: $1"
}

reject_rpm() {
  local status

  if rpm -q "$1" >/dev/null 2>&1; then
    fail "rejected RPM is installed: $1"
  else
    status=$?
  fi
  [[ "$status" -eq 1 ]] || fail "RPM query failed for: $1"
}

require_file() {
  test -f "$1" || fail "required file is missing: $1"
}

require_file_content() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

validate_composed_config() {
  local panel="$1" defaults="$2"
  shift 2

  [[ "$#" -gt 0 ]] || fail 'no XFCE panel plugin descriptor directories supplied'
  python3 - "$panel" "$defaults" "$@" <<'PY'
import configparser
import os
import sys
import xml.etree.ElementTree as ET


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


panel_path, defaults_path, *plugin_directories = sys.argv[1:]

try:
    root = ET.parse(panel_path).getroot()
except (ET.ParseError, OSError) as error:
    fail(f"panel XML is malformed: {error}")

if root.tag != "channel" or root.get("name") != "xfce4-panel":
    fail("panel XML root is not the xfce4-panel channel")

panels = root.find("./property[@name='panels']")
plugins = root.find("./property[@name='plugins']")
if panels is None or plugins is None:
    fail("panel XML is missing panels or plugins")

panel_numbers = [(node.get("type"), node.get("value")) for node in panels.findall("value")]
if panel_numbers != [("int", "1"), ("int", "2")]:
    fail(f"panel list is {panel_numbers!r}, expected panels 1 and 2")

panel_1 = panels.find("./property[@name='panel-1']")
panel_2 = panels.find("./property[@name='panel-2']")
if panel_1 is None or panel_2 is None:
    fail("panel XML is missing panel-1 or panel-2")


def require_property(parent, panel_name, name, expected_type, expected_value):
    node = parent.find(f"./property[@name='{name}']")
    if node is None:
        fail(f"{panel_name}/{name} is missing")
    actual_type = node.get("type")
    actual_value = node.get("value")
    if (actual_type, actual_value) != (expected_type, expected_value):
        fail(
            f"{panel_name}/{name} is {actual_type}:{actual_value}, "
            f"expected {expected_type}:{expected_value}"
        )


require_property(panel_2, "panel-2", "position", "string", "p=10;x=0;y=0")
require_property(panel_2, "panel-2", "length", "uint", "1")
require_property(panel_2, "panel-2", "length-adjust", "bool", "true")
require_property(panel_2, "panel-2", "size", "uint", "48")
require_property(panel_2, "panel-2", "autohide-behavior", "uint", "2")


def plugin_ids(panel, panel_name, expected):
    node = panel.find("./property[@name='plugin-ids']")
    if node is None:
        fail(f"{panel_name}/plugin-ids is missing")
    values = [(value.get("type"), value.get("value")) for value in node.findall("value")]
    expected_values = [("int", str(value)) for value in expected]
    if values != expected_values:
        fail(f"{panel_name} plugin IDs are {values!r}, expected {expected_values!r}")
    return [value for _, value in values]


panel_1_ids = plugin_ids(panel_1, "panel-1", range(1, 11))
panel_2_ids = plugin_ids(panel_2, "panel-2", (11, 12))

plugin_mapping = {}
for node in plugins.findall("property"):
    name = node.get("name")
    if name in plugin_mapping:
        fail(f"duplicate panel plugin mapping: {name}")
    plugin_mapping[name] = node


def resolve_plugins(ids, panel_name):
    resolved = []
    for plugin_id in ids:
        key = f"plugin-{plugin_id}"
        node = plugin_mapping.get(key)
        if node is None:
            fail(f"{panel_name} references missing plugin mapping: {key}")
        if node.get("type") != "string" or not node.get("value"):
            fail(f"{key} does not contain a string plugin name")
        resolved.append(node.get("value"))
    return resolved


panel_1_plugins = resolve_plugins(panel_1_ids, "panel-1")
panel_2_plugins = resolve_plugins(panel_2_ids, "panel-2")
expected_panel_1 = [
    "whiskermenu",
    "tasklist",
    "pager",
    "separator",
    "clock",
    "systray",
    "pulseaudio",
    "power-manager-plugin",
    "notification-plugin",
    "actions",
]
expected_panel_2 = ["docklike", "showdesktop"]
if panel_1_plugins != expected_panel_1:
    fail(f"panel-1 plugin order is {panel_1_plugins!r}, expected {expected_panel_1!r}")
if panel_2_plugins != expected_panel_2:
    fail(f"panel-2 plugin order is {panel_2_plugins!r}, expected {expected_panel_2!r}")

for plugin in dict.fromkeys(panel_1_plugins + panel_2_plugins):
    descriptor = f"{plugin}.desktop"
    if not any(os.path.isfile(os.path.join(directory, descriptor)) for directory in plugin_directories):
        fail(f"panel plugin descriptor is missing: {descriptor}")

parser = configparser.ConfigParser(
    interpolation=None,
    strict=True,
    delimiters=("=",),
    comment_prefixes=("#", ";"),
    inline_comment_prefixes=None,
)
parser.optionxform = str
try:
    with open(defaults_path, encoding="utf-8") as defaults_file:
        parser.read_file(defaults_file)
except (OSError, configparser.Error) as error:
    fail(f"defaults list is malformed: {error}")

section_name = "Default Applications"
if not parser.has_section(section_name):
    fail("defaults list is missing [Default Applications] section")

expected_defaults = {
    "x-scheme-handler/http": "airblue-zen.desktop;",
    "x-scheme-handler/https": "airblue-zen.desktop;",
    "text/html": "airblue-zen.desktop;",
}
for mime_type, expected in expected_defaults.items():
    if not parser.has_option(section_name, mime_type):
        fail(f"missing MIME default: {mime_type}")
    actual = parser.get(section_name, mime_type, raw=True)
    if actual != expected:
        fail(f"MIME default {mime_type} is {actual!r}, expected {expected!r}")
PY
}

validate_browser_helper() {
  local helpers_rc="$1" helper="$2" application="$3"

  python3 - "$helpers_rc" "$helper" "$application" <<'PY'
import configparser
import sys
from pathlib import Path


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


helpers_rc_path, helper_path, application_path = map(Path, sys.argv[1:])
try:
    helper_lines = [
        line.strip()
        for line in helpers_rc_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith(("#", ";"))
    ]
except OSError as error:
    fail(f"XFCE helpers configuration is unreadable: {error}")
if helper_lines != ["WebBrowser=airblue-zen"]:
    fail(f"XFCE WebBrowser helper mapping is {helper_lines!r}, expected airblue-zen")
helper_id = helper_lines[0].split("=", 1)[1]
if helper_path.stem != helper_id:
    fail(f"XFCE WebBrowser helper {helper_id!r} does not match helper filename {helper_path.name!r}")


def desktop_entry(path, label):
    parser = configparser.ConfigParser(
        interpolation=None,
        strict=True,
        delimiters=("=",),
        comment_prefixes=("#", ";"),
        inline_comment_prefixes=None,
    )
    parser.optionxform = str
    try:
        with path.open(encoding="utf-8") as stream:
            parser.read_file(stream)
    except (OSError, configparser.Error) as error:
        fail(f"{label} desktop entry is malformed: {error}")
    if parser.sections() != ["Desktop Entry"]:
        fail(f"{label} desktop entry must contain only [Desktop Entry]")
    return parser["Desktop Entry"]


helper_entry = desktop_entry(helper_path, "XFCE browser helper")
expected_helper = {
    "Type": "X-XFCE-Helper",
    "Name": "Zen Browser",
    "StartupNotify": "true",
    "X-XFCE-Binaries": "flatpak;",
    "X-XFCE-Category": "WebBrowser",
    "X-XFCE-Commands": "flatpak run app.zen_browser.zen;",
    "X-XFCE-CommandsWithParameter": 'flatpak run app.zen_browser.zen "%s";',
}
for key, expected in expected_helper.items():
    actual = helper_entry.get(key, raw=True)
    if actual != expected:
        fail(f"XFCE browser helper {key} is {actual!r}, expected {expected!r}")

if application_path.name != "airblue-zen.desktop":
    fail(f"Zen application filename is {application_path.name!r}, expected airblue-zen.desktop")
application_entry = desktop_entry(application_path, "Zen application")
if application_entry.get("Type", raw=True) != "Application":
    fail("Zen application Type must be Application")
expected_exec = "flatpak run app.zen_browser.zen %U"
if application_entry.get("Exec", raw=True) != expected_exec:
    fail(f"Zen application Exec must be {expected_exec!r}")
PY
}

validate_image_modules() {
  local modules_root="$1" tree version module found
  local -a candidate_trees=() image_trees=()

  shopt -s nullglob
  candidate_trees=("$modules_root"/*)
  shopt -u nullglob
  for tree in "${candidate_trees[@]}"; do
    if test -d "$tree"; then
      image_trees+=("$tree")
    fi
  done
  [[ "${#image_trees[@]}" -gt 0 ]] ||
    fail "no image-owned kernel module trees found under $modules_root"

  for module in brcmsmac uvcvideo i915 hid_apple applesmc; do
    found=false
    for tree in "${image_trees[@]}"; do
      version="${tree##*/}"
      if modinfo -k "$version" "$module" >/dev/null 2>&1; then
        found=true
        break
      fi
    done
    [[ "$found" == true ]] ||
      fail "kernel module metadata is missing from image-owned trees: $module"
  done
}

require_unit_state() {
  local unit="$1" expected="$2" state status expected_status

  if state="$(systemctl is-enabled "$unit" 2>/dev/null)"; then
    status=0
  else
    status=$?
  fi

  if [[ "$expected" == disabled && "$state" == masked* ]]; then
    fail "$unit is masked; it must remain available but disabled"
  fi

  case "$expected" in
    enabled) expected_status=0 ;;
    disabled) expected_status=1 ;;
    *) fail "unsupported expected state for $unit: $expected" ;;
  esac

  [[ "$state" == "$expected" && "$status" -eq "$expected_status" ]] ||
    fail "$unit state is ${state:-unknown} (status $status), expected $expected (status $expected_status)"
}

case "${1:-}" in
  --validate-config)
    [[ "$#" -ge 4 ]] ||
      fail 'usage: test-image.sh --validate-config PANEL DEFAULTS PLUGIN_DIRECTORY...'
    validate_composed_config "$2" "$3" "${@:4}"
    printf 'image config validation: PASS\n'
    exit 0
    ;;
  --validate-modules)
    [[ "$#" -eq 2 ]] || fail 'usage: test-image.sh --validate-modules MODULES_ROOT'
    validate_image_modules "$2"
    printf 'image module validation: PASS\n'
    exit 0
    ;;
  --validate-helper)
    [[ "$#" -eq 4 ]] ||
      fail 'usage: test-image.sh --validate-helper HELPERS_RC HELPER_DESKTOP APPLICATION_DESKTOP'
    validate_browser_helper "$2" "$3" "$4"
    printf 'image helper validation: PASS\n'
    exit 0
    ;;
  '') ;;
  *) fail "unknown argument: $1" ;;
esac

for package in \
  lightdm \
  lightdm-gtk \
  xfce4-session \
  xfce4-panel \
  xfce4-settings \
  xfconf \
  xfwm4 \
  xfdesktop \
  Thunar \
  xfce4-terminal \
  mousepad \
  xarchiver \
  xfce4-notifyd \
  xfce4-power-manager \
  NetworkManager-wifi \
  NetworkManager-bluetooth \
  network-manager-applet \
  ModemManager \
  xfce4-pulseaudio-plugin \
  xfce4-whiskermenu-plugin \
  xfce4-docklike-plugin \
  xfce4-places-plugin \
  xfce4-screenshooter-plugin \
  xfce4-xkb-plugin \
  pipewire \
  pipewire-pulseaudio \
  wireplumber \
  upower \
  bluez \
  bluez-obexd \
  cups \
  flatpak \
  podman \
  distrobox \
  fwupd \
  linux-firmware \
  mesa-dri-drivers \
  libinput \
  papirus-icon-theme \
  gtk-murrine-engine \
  sassc \
  git-core; do
  require_rpm "$package"
done

for package in \
  gnome-shell \
  firefox \
  firefox-langpacks \
  toolbox \
  xfce4-session-wayland-session; do
  reject_rpm "$package"
done

for path in \
  /usr/share/themes/Orchis/index.theme \
  /usr/share/themes/Orchis-Dark/index.theme \
  /usr/share/icons/Papirus-Dark/index.theme \
  /usr/share/icons/Bibata-Modern-Classic/index.theme \
  /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml \
  /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml \
  /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml \
  /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml \
  /etc/xdg/xfce4/helpers.rc \
  /etc/xdg/xfce4/panel/docklike.rc \
  /usr/share/xfce4/helpers/airblue-zen.desktop \
  /usr/share/applications/airblue-zen.desktop \
  /usr/share/applications/airblue-bazaar.desktop \
  /usr/share/applications/defaults.list \
  /usr/share/xsessions/xfce.desktop; do
  require_file "$path"
done

for wayland_session in \
  /usr/share/wayland-sessions/xfce.desktop \
  /usr/share/wayland-sessions/xfce-wayland.desktop; do
  if test -e "$wayland_session" || test -L "$wayland_session"; then
    fail "default XFCE Wayland session must not be installed: $wayland_session"
  fi
done

require_file_content /etc/xdg/xfce4/panel/docklike.rc \
  'pinned=airblue-zen.desktop;airblue-bazaar.desktop;thunar.desktop;xfce4-terminal.desktop;'
require_file_content /etc/xdg/xfce4/helpers.rc 'WebBrowser=airblue-zen'
require_file_content /usr/share/xfce4/helpers/airblue-zen.desktop \
  'X-XFCE-Commands=flatpak run app.zen_browser.zen;'
validate_browser_helper \
  /etc/xdg/xfce4/helpers.rc \
  /usr/share/xfce4/helpers/airblue-zen.desktop \
  /usr/share/applications/airblue-zen.desktop

validate_composed_config \
  /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml \
  /usr/share/applications/defaults.list \
  /usr/share/xfce4/panel/plugins \
  /usr/lib64/xfce4/panel/plugins

require_unit_state lightdm.service enabled
require_unit_state cups.socket enabled
require_unit_state ModemManager.service disabled

if display_manager_target="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)"; then
  :
else
  fail "display-manager.service alias is missing"
fi
[[ "$display_manager_target" == /usr/lib/systemd/system/lightdm.service ]] ||
  fail "display-manager.service points to $display_manager_target, expected LightDM"

validate_image_modules /usr/lib/modules

printf 'image smoke test: PASS\n'
