#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mutate_and_expect_rejection() {
  local name="$1" command="$2" mode="$3"
  local tempdir
  tempdir="$(mktemp -d)"
  trap 'rm -rf "$tempdir"' RETURN
  mkdir -p "$tempdir/tests"
  cp "$repo_root/README.md" "$tempdir/README.md"
  cp "$repo_root/tests/test-readme.sh" "$tempdir/tests/test-readme.sh"

  python3 - "$tempdir/README.md" "$command" "$mode" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
command = sys.argv[2]
mode = sys.argv[3]
text = path.read_text()
needle = command + "\n"
if text.count(needle) != 1:
    raise SystemExit(f"expected one executable {command!r}, found {text.count(needle)}")
if mode == "remove":
    text = text.replace(needle, "true\n", 1)
elif mode == "move":
    text = text.replace(needle, "", 1) + f"\n{command}\n"
else:
    raise SystemExit(f"unsupported mutation mode: {mode}")
path.write_text(text)
PY

  if bash "$tempdir/tests/test-readme.sh" >/dev/null 2>&1; then
    printf 'FAIL: README validator accepted %s %s without its fenced command\n' "$name" "$mode" >&2
    return 1
  fi
}

mutate_caveat_and_expect_rejection() {
  local tempdir
  tempdir="$(mktemp -d)"
  trap 'rm -rf "$tempdir"' RETURN
  mkdir -p "$tempdir/tests"
  cp "$repo_root/README.md" "$tempdir/README.md"
  cp "$repo_root/tests/test-readme.sh" "$tempdir/tests/test-readme.sh"

  python3 - "$tempdir/README.md" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
pattern = r"boots far\s+enough to run it"
if len(re.findall(pattern, text)) != 1:
    raise SystemExit(f"expected one rollback caveat, found {len(re.findall(pattern, text))}")
path.write_text(re.sub(pattern, "boots normally", text, count=1))
PY

  if bash "$tempdir/tests/test-readme.sh" >/dev/null 2>&1; then
    printf 'FAIL: README validator accepted weakened rollback terminal caveat\n' >&2
    return 1
  fi
}

mutate_section_order_and_expect_rejection() {
  local tempdir
  tempdir="$(mktemp -d)"
  trap 'rm -rf "$tempdir"' RETURN
  mkdir -p "$tempdir/tests"
  cp "$repo_root/README.md" "$tempdir/README.md"
  cp "$repo_root/tests/test-readme.sh" "$tempdir/tests/test-readme.sh"

  python3 - "$tempdir/README.md" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
two = re.search(r"(?ms)^### 2\. .+?(?=^### 3\. )", text)
three = re.search(r"(?ms)^### 3\. .+?(?=^### 4\. )", text)
if two is None or three is None:
    raise SystemExit("could not locate complete acceptance sections 2 and 3")
path.write_text(text[:two.start()] + three.group() + two.group() + text[three.end():])
PY

  if bash "$tempdir/tests/test-readme.sh" >/dev/null 2>&1; then
    printf 'FAIL: README validator accepted swapped acceptance sections 2 and 3\n' >&2
    return 1
  fi
}

for mode in remove move; do
  mutate_and_expect_rejection 'Wi-Fi PCI check' 'lspci -k' "$mode"
  mutate_and_expect_rejection 'audio server check' 'pactl info' "$mode"
  mutate_and_expect_rejection 'battery check' 'upower -e' "$mode"
done
mutate_caveat_and_expect_rejection
mutate_section_order_and_expect_rejection
printf 'readme validator mutations: PASS\n'
