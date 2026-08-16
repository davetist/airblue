# Airblue

Airblue is a signed Fedora 44 Atomic XFCE image for the Apple MacBook Air 5,1
(11-inch, Mid 2012). It retains Fedora's kernel, Mesa, firmware, boot stack,
and Atomic updates; it does not add proprietary hardware drivers.

## Before you start

Start from a supported Fedora Silverblue installation and back up unsynchronized
data. The commands below retain a pinned Silverblue deployment for recovery. Do
**not** unpin it until every hardware acceptance check has passed.

Replace `OWNER` with the GitHub organization or user that publishes the image.
Each command block that uses `$IMAGE` assigns it first, so it remains safe to
copy after a reboot or into a new terminal.

Before first publication, the repository maintainer must configure GitHub
Actions `SIGNING_SECRET` with the private key whose public half exactly matches
the committed repository-root `cosign.pub`. A mismatch makes signed builds,
installed policy, and independent verification fail. This is a maintainer-only
prerequisite: keep the private key out of Git, logs, issues, and consumer
installation instructions.

## Install and enable signed updates

Pin the current Silverblue deployment, inspect it, then make the initial
unsigned rebase:

```bash
IMAGE=ghcr.io/OWNER/airblue
sudo ostree admin pin 0
rpm-ostree status
sudo rpm-ostree rebase ostree-unverified-registry:$IMAGE:latest
systemctl reboot
```

The first unsigned switch is intentional: it installs the image signing policy
and public key. After rebooting, switch to the signed transport so subsequent
image updates are signature-enforced:

```bash
IMAGE=ghcr.io/OWNER/airblue
sudo rpm-ostree rebase ostree-image-signed:docker://$IMAGE:latest
systemctl reboot
```

Keep the pinned Silverblue deployment until the acceptance checklist below is
complete.

## Updates and signature verification

Update the operating-system image and Flatpaks separately:

```bash
sudo rpm-ostree upgrade
flatpak update
systemctl reboot
```

The reboot activates the staged operating-system deployment. After the reboot,
confirm the active deployment:

```bash
rpm-ostree status
```

From a checkout of this repository, where `cosign.pub` is the reviewed public
key, independently verify the current image tag:

```bash
IMAGE=ghcr.io/OWNER/airblue
cosign verify --key cosign.pub $IMAGE:latest
```

## Recovery and rollback

To recover specifically to Silverblue if Airblue does not boot, select the
pinned Silverblue deployment in the boot menu. If the new deployment reaches a
terminal, `rpm-ostree rollback` instead swaps to the immediately previous
deployment:

```bash
sudo rpm-ostree rollback
systemctl reboot
```

After the signed rebase, the immediately previous deployment may be the
unsigned Airblue deployment rather than the pinned Silverblue deployment.
`rpm-ostree rollback` therefore applies only when the new deployment boots far
enough to run it and is not the recovery method to choose specifically for
Silverblue; otherwise select the pinned Silverblue deployment in the boot menu.

## Target-hardware acceptance checklist

Run these checks on the target MacBook Air 5,1 after the signed rebase. Each is
an acceptance gate, not a claim for unrelated hardware. Record the result and
leave the Silverblue deployment pinned until all ten pass.

### 1. LightDM/existing-user XFCE login

At the LightDM greeter, sign in with the existing Silverblue user. In the
session, run:

```bash
systemctl is-active display-manager.service
printf '%s\n' "$XDG_SESSION_TYPE" "$XDG_CURRENT_DESKTOP"
```

Pass: the service is `active`, the session is X11/XFCE, and that existing user
reaches the XFCE desktop with the expected panel and dock.

### 2. Wi-Fi reboot and suspend transfer

Confirm the in-kernel Broadcom driver and network transfer, then repeat the
network checks after a reboot and suspend/resume:

```bash
lspci -k
nmcli device status
curl -I https://example.com
```

Pass: the Broadcom wireless entry reports `brcmsmac` in `lspci -k`, Wi-Fi
reconnects after reboot and suspend/resume, and the HTTP request succeeds each
time without a manual driver change.

### 3. Bluetooth discovery/connect

Enable Bluetooth, discover a nearby device, and connect it using the Bluetooth
panel or `bluetoothctl`:

```bash
systemctl is-active bluetooth.service
bluetoothctl --timeout 15 scan on
```

Pass: the service is `active`, a nearby device appears during the scan, and it
can connect and remain connected long enough to use it.

### 4. FaceTime HD camera in a Flatpak

Confirm the built-in camera is present, then open a Flatpak application with
camera permission and select the FaceTime HD camera for a live preview:

```bash
lsusb -d 05ac:8510
flatpak list --app
```

Pass: the USB command lists `05ac:8510`, and the chosen Flatpak shows live
video from the built-in camera. Install a test application through Bazaar if
needed; no proprietary camera driver is required.

### 5. Speaker/headphone/microphone audio

Inspect the PipeWire/PulseAudio server, then test internal speakers, headphone
output, and microphone capture with XFCE audio controls:

```bash
pactl info
wpctl status
```

Pass: `pactl info` reports a running server, speakers produce audio, inserting
headphones selects a usable output, and microphone input meters and records.

### 6. Brightness/keyboard/trackpad/battery

Exercise brightness keys, normal keyboard input, and the trackpad, then inspect
the available battery devices:

```bash
upower -e
libinput list-devices
```

Pass: brightness visibly changes, keyboard and trackpad input work normally,
and `upower -e` lists a battery device with changing charge state on/off AC.

### 7. Suspend/resume with input/network/display

Suspend the running session, wake it, and immediately inspect networking:

```bash
systemctl suspend
nmcli device status
```

Pass: after wake, the display returns, keyboard and trackpad input work, and
Wi-Fi reconnects without restarting the session or manually loading a driver.

### 8. Zen HTTP/HTTPS defaults

Check the registered handlers, then open an HTTPS link from the host desktop:

```bash
xdg-mime query default x-scheme-handler/http
xdg-mime query default x-scheme-handler/https
xdg-open https://example.com
```

Pass: both MIME queries report `airblue-zen.desktop`, and the link opens in Zen
Browser rather than prompting for another browser.

### 9. Bazaar install/remove from Flathub

Confirm the system Flathub remote, then use Bazaar to install and remove a
small test application from Flathub:

```bash
flatpak remotes --system
flatpak list --app
```

Pass: `flathub` appears as a system remote, Bazaar completes both actions, and
the test app appears after installation and disappears after removal in
`flatpak list --app`.

### 10. Distrobox create/enter/remove with Podman

Create a temporary Fedora container, enter it and confirm its release, exit,
then remove it:

```bash
distrobox create --name airblue-test --image registry.fedoraproject.org/fedora:44
distrobox enter airblue-test
cat /etc/fedora-release
exit
distrobox rm airblue-test
```

Pass: creation completes with Podman, the container opens a Fedora 44 shell,
and removal succeeds after exiting. Airblue does not create or manage Distrobox
containers automatically.

## Scope

Airblue's supported default is XFCE on X11 for the MacBook Air 5,1. It does not
promise a Wayland XFCE session, NVIDIA or arbitrary-computer support, automatic
theme scheduling, a large bundled application suite, or aggressive removal of
optional system capabilities.
