#!/usr/bin/env bash
set -euo pipefail

ORCHIS_REPO=https://github.com/vinceliuice/Orchis-theme.git
ORCHIS_COMMIT=50882dcfa96883b29be4c9091af188ccf8848f1e
BIBATA_REPO=https://github.com/ful1e5/Bibata_Cursor.git
BIBATA_COMMIT=b420533bc314ab08611586f691673f1f77475d1e
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

git clone --filter=blob:none "$ORCHIS_REPO" "$workdir/orchis"
git -C "$workdir/orchis" checkout --detach "$ORCHIS_COMMIT"
(
  cd "$workdir/orchis"
  ./install.sh --dest /usr/share/themes --theme default --color standard dark --size standard
)

git clone --filter=blob:none "$BIBATA_REPO" "$workdir/bibata"
git -C "$workdir/bibata" checkout --detach "$BIBATA_COMMIT"
(
  cd "$workdir/bibata"
  yarn install --frozen-lockfile
  yarn generate
)
install -d /usr/share/icons
cp -a "$workdir/bibata/themes/Bibata-Modern-Classic" /usr/share/icons/

test -f /usr/share/themes/Orchis/index.theme
test -f /usr/share/themes/Orchis-Dark/index.theme
test -f /usr/share/icons/Bibata-Modern-Classic/index.theme
