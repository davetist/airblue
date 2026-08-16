#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_test="$repo_root/tests/test-image.sh"
source_panel="$repo_root/files/system/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
source_defaults="$repo_root/files/system/usr/share/applications/defaults.list"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

validate_thunar_rpm_contract() {
  local script="$1"

  grep -Fqx '  Thunar \' "$script" || {
    printf 'FAIL: image smoke must query case-sensitive Fedora RPM name: Thunar\n' >&2
    return 1
  }
  if grep -Fqx '  thunar \' "$script"; then
    printf 'FAIL: image smoke must not query lowercase RPM name: thunar\n' >&2
    return 1
  fi
}

validate_thunar_rpm_contract "$image_test"

make_config_fixture() {
  local name="$1" fixture="$workdir/$1" plugin

  mkdir -p "$fixture/plugins"
  cp "$source_panel" "$fixture/panel.xml"
  cp "$source_defaults" "$fixture/defaults.list"
  for plugin in \
    whiskermenu \
    tasklist \
    pager \
    separator \
    clock \
    systray \
    pulseaudio \
    power-manager-plugin \
    notification-plugin \
    actions \
    docklike \
    showdesktop; do
    touch "$fixture/plugins/$plugin.desktop"
  done
}

run_config_validator() {
  local fixture="$1"

  bash "$image_test" --validate-config \
    "$fixture/panel.xml" \
    "$fixture/defaults.list" \
    "$fixture/plugins"
}

expect_config_failure() {
  local fixture="$1" expected="$2" output

  if output="$(run_config_validator "$fixture" 2>&1)"; then
    fail "invalid fixture unexpectedly passed: ${fixture##*/}"
  fi
  [[ "$output" == *"$expected"* ]] ||
    fail "${fixture##*/} failed without expected message '$expected': $output"
}

make_config_fixture valid
if ! output="$(run_config_validator "$workdir/valid" 2>&1)"; then
  fail "valid config fixture was rejected: $output"
fi
[[ "$output" == 'image config validation: PASS' ]] ||
  fail "valid config emitted unexpected output: $output"

make_config_fixture malformed
printf '<' >> "$workdir/malformed/panel.xml"
expect_config_failure "$workdir/malformed" 'panel XML is malformed'

make_config_fixture wrong-position
sed -i 's/p=10;x=0;y=0/p=9;x=0;y=0/' "$workdir/wrong-position/panel.xml"
expect_config_failure "$workdir/wrong-position" 'panel-2/position'

make_config_fixture noncompact-dock
sed -i 's/name="length" type="uint" value="1"/name="length" type="uint" value="100"/' \
  "$workdir/noncompact-dock/panel.xml"
expect_config_failure "$workdir/noncompact-dock" 'panel-2/length'

make_config_fixture fixed-dock-length
sed -i 's/name="length-adjust" type="bool" value="true"/name="length-adjust" type="bool" value="false"/' \
  "$workdir/fixed-dock-length/panel.xml"
expect_config_failure "$workdir/fixed-dock-length" 'panel-2/length-adjust'

make_config_fixture wrong-size
sed -i 's/name="size" type="uint" value="48"/name="size" type="uint" value="40"/' \
  "$workdir/wrong-size/panel.xml"
expect_config_failure "$workdir/wrong-size" 'panel-2/size'

make_config_fixture wrong-autohide
sed -i 's/name="autohide-behavior" type="uint" value="2"/name="autohide-behavior" type="uint" value="1"/' \
  "$workdir/wrong-autohide/panel.xml"
expect_config_failure "$workdir/wrong-autohide" 'panel-2/autohide-behavior'

make_config_fixture wrong-top-order
sed -i \
  -e 's/name="plugin-1" type="string" value="whiskermenu"/name="plugin-1" type="string" value="tasklist"/' \
  -e 's/name="plugin-2" type="string" value="tasklist"/name="plugin-2" type="string" value="whiskermenu"/' \
  "$workdir/wrong-top-order/panel.xml"
expect_config_failure "$workdir/wrong-top-order" 'panel-1 plugin order'

make_config_fixture wrong-dock-order
sed -i \
  -e 's/name="plugin-11" type="string" value="docklike"/name="plugin-11" type="string" value="showdesktop"/' \
  -e 's/name="plugin-12" type="string" value="showdesktop"/name="plugin-12" type="string" value="docklike"/' \
  "$workdir/wrong-dock-order/panel.xml"
expect_config_failure "$workdir/wrong-dock-order" 'panel-2 plugin order'

make_config_fixture plugin-typo
sed -i 's/value="docklike"/value="docklike-typo"/' "$workdir/plugin-typo/panel.xml"
expect_config_failure "$workdir/plugin-typo" 'panel-2 plugin order'

make_config_fixture missing-descriptor
rm "$workdir/missing-descriptor/plugins/docklike.desktop"
expect_config_failure "$workdir/missing-descriptor" 'panel plugin descriptor is missing: docklike.desktop'

make_config_fixture missing-mime
sed -i '/^x-scheme-handler\/https=/d' "$workdir/missing-mime/defaults.list"
expect_config_failure "$workdir/missing-mime" 'missing MIME default: x-scheme-handler/https'

make_config_fixture conflicting-mime
printf 'x-scheme-handler/http=other.desktop;\n' >> "$workdir/conflicting-mime/defaults.list"
expect_config_failure "$workdir/conflicting-mime" 'defaults list is malformed'

make_config_fixture nonexact-mime
sed -i \
  's#^x-scheme-handler/http=airblue-zen.desktop;$#x-scheme-handler/http=other.desktop;airblue-zen.desktop;#' \
  "$workdir/nonexact-mime/defaults.list"
expect_config_failure "$workdir/nonexact-mime" 'MIME default x-scheme-handler/http'

make_config_fixture wrong-mime-section
sed -i 's/^\[Default Applications\]$/[Added Associations]/' \
  "$workdir/wrong-mime-section/defaults.list"
expect_config_failure "$workdir/wrong-mime-section" 'missing [Default Applications] section'

module_root="$workdir/modules"
empty_module_root="$workdir/empty-modules"
mkdir -p \
  "$module_root/6.8.0-airblue" \
  "$module_root/6.9.1-airblue" \
  "$empty_module_root"
MODINFO_LOG="$workdir/modinfo.log"
export MODINFO_LOG
: > "$MODINFO_LOG"

modinfo() {
  printf '%s\n' "$*" >> "$MODINFO_LOG"
  [[ "$#" -eq 3 && "$1" == -k ]] || return 64
  [[ "$2" == 6.9.1-airblue ]] || return 1
  [[ "${MODINFO_MISSING:-}" != "$3" ]]
}
export -f modinfo

if ! output="$(bash "$image_test" --validate-modules "$module_root" 2>&1)"; then
  fail "image-owned module fixture was rejected: $output"
fi
[[ "$output" == 'image module validation: PASS' ]] ||
  fail "module validator emitted unexpected output: $output"

if awk 'NF != 3 || $1 != "-k" || ($2 != "6.8.0-airblue" && $2 != "6.9.1-airblue") {exit 1}' \
  "$MODINFO_LOG"; then
  :
else
  fail 'modinfo was called without an explicit image-owned kernel version'
fi

if output="$(bash "$image_test" --validate-modules "$empty_module_root" 2>&1)"; then
  fail 'empty image module tree unexpectedly passed'
fi
[[ "$output" == *'no image-owned kernel module trees found'* ]] ||
  fail "empty module tree failed unexpectedly: $output"

if output="$(MODINFO_MISSING=applesmc bash "$image_test" --validate-modules "$module_root" 2>&1)"; then
  fail 'missing image-owned module metadata unexpectedly passed'
fi
[[ "$output" == *'kernel module metadata is missing from image-owned trees: applesmc'* ]] ||
  fail "missing module metadata failed unexpectedly: $output"

lowercase_thunar="$workdir/lowercase-thunar.sh"
cp "$image_test" "$lowercase_thunar"
sed -i 's/Thunar/thunar/' "$lowercase_thunar"
if output="$(validate_thunar_rpm_contract "$lowercase_thunar" 2>&1)"; then
  fail 'lowercase Thunar RPM mutation unexpectedly passed'
fi
[[ "$output" == *'case-sensitive Fedora RPM name: Thunar'* ]] ||
  fail "lowercase Thunar mutation failed unexpectedly: $output"

printf 'image validator fixtures: PASS\n'
