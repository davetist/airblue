#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readme="$repo_root/README.md"

python3 - "$readme" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
normalized_text = re.sub(r"\s+", " ", text)

def fail(message):
    raise SystemExit(f"FAIL: {message}")

def require(fragment):
    if re.sub(r"\s+", " ", fragment) not in normalized_text:
        fail(f"README is missing: {fragment}")

def require_absent(fragment):
    if fragment in text:
        fail(f"README unexpectedly contains: {fragment}")

bash_blocks = re.findall(r"```bash\n(.*?)```", text, re.DOTALL)

def bash_block_containing(fragment):
    for block in bash_blocks:
        if fragment in block:
            return block
    fail(f"no Bash block contains: {fragment}")

def require_order(value, *fragments):
    value = re.sub(r"\s+", " ", value)
    position = -1
    for fragment in fragments:
        fragment = re.sub(r"\s+", " ", fragment)
        next_position = value.find(fragment, position + 1)
        if next_position < 0:
            fail(f"missing or out-of-order: {fragment}")
        position = next_position

image = "IMAGE=ghcr.io/davetist/airblue"
if "OWNER" in text:
    fail("README still contains the OWNER placeholder")
for block in bash_blocks:
    if "$IMAGE" in block:
        if block.find(image) < 0 or block.find(image) > block.find("$IMAGE"):
            fail("each Bash block using $IMAGE must assign it before use")

unsigned = bash_block_containing("ostree-unverified-registry:$IMAGE:latest")
require_order(
    unsigned,
    image,
    "sudo ostree admin pin 0",
    "rpm-ostree status",
    "sudo rpm-ostree rebase ostree-unverified-registry:$IMAGE:latest",
    "systemctl reboot",
)

signed = bash_block_containing("ostree-image-signed:docker://$IMAGE:latest")
require_order(
    signed,
    image,
    "sudo rpm-ostree rebase ostree-image-signed:docker://$IMAGE:latest",
    "systemctl reboot",
)

verification = bash_block_containing("cosign verify --key cosign.pub $IMAGE:latest")
require_order(verification, image, "cosign verify --key cosign.pub $IMAGE:latest")

updates = re.search(
    r"## Updates and signature verification\n(.*?)(?=\n## )", text, re.DOTALL
)
if updates is None:
    fail("missing updates section")
require_order(
    updates.group(1),
    "sudo rpm-ostree upgrade",
    "flatpak update",
    "systemctl reboot",
    "rpm-ostree status",
)

require("private key whose public half exactly matches the committed repository-root `cosign.pub`")
require("A mismatch makes signed builds, installed policy, and independent verification fail")

recovery = re.search(r"## Recovery and rollback\n(.*?)(?=\n## )", text, re.DOTALL)
if recovery is None:
    fail("missing recovery section")
require_order(
    recovery.group(1),
    "select the pinned Silverblue deployment in the boot menu",
    "immediately previous deployment",
    "may be the unsigned Airblue deployment",
)
require("rpm-ostree rollback")
require_order(
    recovery.group(1),
    "new deployment reaches a terminal",
    "rpm-ostree rollback",
    "boots far enough to run it",
)

require("distrobox rm airblue-test")
require_absent("distrobox rm --name airblue-test")

for heading in (
    "1. LightDM/existing-user XFCE login",
    "2. Wi-Fi reboot and suspend transfer",
    "3. Bluetooth discovery/connect",
    "4. FaceTime HD camera in a Flatpak",
    "5. Speaker/headphone/microphone audio",
    "6. Brightness/keyboard/trackpad/battery",
    "7. Suspend/resume with input/network/display",
    "8. Zen HTTP/HTTPS defaults",
    "9. Bazaar install/remove from Flathub",
    "10. Distrobox create/enter/remove with Podman",
):
    require(heading)

section_matches = list(re.finditer(r"^### (\d+)\. .+$", text, re.MULTILINE))
heading_numbers = [int(match.group(1)) for match in section_matches]
if heading_numbers != list(range(1, 11)):
    fail(
        "acceptance headings must appear exactly once in order 1 through 10; "
        f"found {heading_numbers}"
    )
sections = {
    int(match.group(1)): text[
        match.end(): section_matches[index + 1].start()
        if index + 1 < len(section_matches)
        else len(text)
    ]
    for index, match in enumerate(section_matches)
}

def require_section(number):
    if number not in sections:
        fail(f"missing acceptance section {number}")
    return sections[number]

def require_bash_command(number, command):
    for block in re.findall(r"```bash\n(.*?)```", require_section(number), re.DOTALL):
        if command in [line.strip() for line in block.splitlines()]:
            return
    fail(f"section {number} has no Bash command: {command}")

def require_bash_order(number, *commands):
    for block in re.findall(r"```bash\n(.*?)```", require_section(number), re.DOTALL):
        lines = [line.strip() for line in block.splitlines()]
        positions = []
        for command in commands:
            try:
                positions.append(lines.index(command))
            except ValueError:
                break
        else:
            if positions == sorted(positions):
                return
    fail(f"section {number} has no ordered Bash sequence: {', '.join(commands)}")

def require_section_phrase(number, phrase):
    section = re.sub(r"\s+", " ", require_section(number))
    if re.sub(r"\s+", " ", phrase) not in section:
        fail(f"section {number} is missing: {phrase}")

for number, commands in {
    1: (
        "systemctl is-active display-manager.service",
        r'''printf '%s\n' "$XDG_SESSION_TYPE" "$XDG_CURRENT_DESKTOP"''',
    ),
    2: ("lspci -k", "nmcli device status", "curl -I https://example.com"),
    3: ("systemctl is-active bluetooth.service", "bluetoothctl --timeout 15 scan on"),
    4: ("lsusb -d 05ac:8510", "flatpak list --app"),
    5: ("pactl info", "wpctl status"),
    6: ("upower -e", "libinput list-devices"),
    7: ("systemctl suspend", "nmcli device status"),
    8: (
        "xdg-mime query default x-scheme-handler/http",
        "xdg-mime query default x-scheme-handler/https",
        "xdg-open https://example.com",
    ),
    9: ("flatpak remotes --system", "flatpak list --app"),
}.items():
    for command in commands:
        require_bash_command(number, command)

require_section_phrase(9, "use Bazaar to install and remove a small test application from Flathub")
require_bash_order(
    10,
    "distrobox create --name airblue-test --image registry.fedoraproject.org/fedora:44",
    "distrobox enter airblue-test",
    "cat /etc/fedora-release",
    "exit",
    "distrobox rm airblue-test",
)

print("readme semantic contract: PASS")
PY
