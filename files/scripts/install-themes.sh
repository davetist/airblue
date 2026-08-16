#!/usr/bin/env bash
set -euo pipefail

ORCHIS_REPO=https://github.com/vinceliuice/Orchis-theme.git
ORCHIS_COMMIT=50882dcfa96883b29be4c9091af188ccf8848f1e
BIBATA_URL=https://github.com/ful1e5/Bibata_Cursor/releases/download/v2.0.7/Bibata-Modern-Classic.tar.xz
BIBATA_SHA256=7d3495864e5bbef02f5e77de760b2905903b63c71495a78ef6306d19a3b556d8
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

git clone --filter=blob:none "$ORCHIS_REPO" "$workdir/orchis"
git -C "$workdir/orchis" checkout --detach "$ORCHIS_COMMIT"
(
  cd "$workdir/orchis"
  ./install.sh --dest /usr/share/themes --theme default --color standard dark --size standard
)

bibata_archive="$workdir/Bibata-Modern-Classic.tar.xz"
bibata_extract="$workdir/bibata-release"
curl --fail --location --show-error --silent --retry 5 --retry-all-errors --output "$bibata_archive" "$BIBATA_URL"
printf '%s  %s\n' "$BIBATA_SHA256" "$bibata_archive" | sha256sum --check -
install -d "$bibata_extract"
tar --extract --xz --file "$bibata_archive" --directory "$bibata_extract" --no-same-owner
test -f "$bibata_extract/Bibata-Modern-Classic/index.theme"
install -d /usr/share/icons
cp -a "$bibata_extract/Bibata-Modern-Classic" /usr/share/icons/

test -f /usr/share/themes/Orchis/index.theme
test -f /usr/share/themes/Orchis-Dark/index.theme
test -f /usr/share/icons/Bibata-Modern-Classic/index.theme
