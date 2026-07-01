# Generic-OS ISO builder

Builds the Generic-OS Debian 13 (trixie) installable ISOs with the dotfiles desktop,
apps, services, and theming **baked in**. The build host (online) pulls the
latest software; the resulting ISOs **install with zero internet**.

- **Base:** Debian 13, Plasma 6 / Wayland. Codename is one knob (`config.env`).
- **Editions:** `everything`, `security` (Kali repo + curated tools), `gaming` —
  each defined declaratively in `editions/<name>.env`.
- **GPU variants:** `universal` (Mesa — AMD/Intel out of box) and `nvidia` (driver baked in).
- **Installer:** Calamares (clones the live squashfs to disk → offline install).

## Quick start
**Containerized (recommended)** — host only needs a container runtime (auto-installs
`podman` if absent); the live-build toolchain lives in the image:
```bash
cd iso
sudo ./container-build.sh             # build every edition → out/*.iso
sudo ./container-build.sh security    # one edition
sudo ./container-build.sh clean       # remove build artifacts, KEEP cache/ (fast rebuilds)
sudo ./container-build.sh purge       # also drop the download cache + build image
```
**Speed:** the first build is download-bound (~GBs). `clean` keeps the package/bootstrap
**cache**, so later builds skip the downloads. Squashfs uses **zstd** (`SQUASHFS_LEVEL`
in config.env) instead of slow xz, and dpkg runs with `force-unsafe-io` during the build —
together cutting a warm rebuild well under the first run. Build one edition at a time.
**On-host** (runs live-build directly):
```bash
sudo apt install live-build rsync gpg curl    # trixie host
sudo ./build.sh                # every edition in $EDITIONS → out/*.iso
sudo ./build.sh security       # one edition
```
Default build produces 5 ISOs: `everything`×{universal,nvidia}, `security`×{universal},
`gaming`×{universal,nvidia}. Output: `out/<suite>-<edition>-<variant>.iso`.

Update the desktop: edit anything under `../config/` or `../config/apps/apps.toml`,
then re-run the build.

## Editions
| Edition | Stacks | Kali repo | Kali tools baked | App tiers | Variants |
|---------|--------|-----------|------------------|-----------|----------|
| `everything` | dev + security + gaming | yes (pinned-low) | no | all | universal, nvidia |
| `security` | dev + security | yes (pinned-low) | curated top set | all | universal |
| `gaming` | dev + gaming | no | no | tier 1 (core) | universal, nvidia |

Edit an edition, or add a new one, by editing/creating `editions/<name>.env` and
listing it in `EDITIONS` (config.env). See [`docs/DEVELOPER.md`](docs/DEVELOPER.md).

## Validate built ISOs
**On-disk (fast, no boot)** — structure + squashfs contents:
```bash
sudo ./validate-iso.sh              # all iso/out/*.iso
```
Structural checks (ISO 9660, bootable, El Torito) need no root; content checks
mount the squashfs (need `sudo`) and confirm each edition has the right software
(Plasma, zsh/nvim, Calamares, **grub bootloader**, Kali repo/tools, Steam, NVIDIA
driver, themed `/etc/skel`) and that build-only cruft was removed.

**Runtime (boots each ISO in QEMU)** — proves the desktop is actually wired up:
```bash
./validate-boot.sh                  # boots each ISO, screenshots + in-guest checks
```
Needs QEMU + `/dev/kvm` (be in the `kvm` group or use sudo). For every ISO it
boots the live session, saves a **screenshot** of the running desktop, and via
the guest agent checks that **conky is running**, the **cyberpunk theme is
applied**, dotfiles landed in the live user's home (`~/.zshrc`,
`~/.config/kdeglobals`, `autostart/conky.desktop`), and apps launch. Artifacts
(`<name>.png` + `<name>.report.txt`) land in `out/boot-validate/`. Requires ISOs
built from current source (they add `qemu-guest-agent` + live autologin).

## Docs
- [`docs/USER.md`](docs/USER.md) — install from the ISO and what you get.
- [`docs/DEVELOPER.md`](docs/DEVELOPER.md) — architecture, how to extend, internals.

## Layout
| Path | Purpose |
|------|---------|
| `config.env` | Build parameters (suite, arch, editions list, Kali key pin). |
| `editions/*.env` | Declarative edition definitions (stacks, tiers, Kali, variants). |
| `container-build.sh` | Containerized build (recommended): trixie+live-build image → runs `build.sh` in a `--privileged --rm` container; `clean` removes container/image/artifacts. |
| `build.sh` | Orchestrator: per edition×variant → sync → stage → `lb config`/`build`. |
| `auto/` | live-build `lb config/build/clean` steps. |
| `config/package-lists/*.list.chroot` | Always-on package sets (base, plasma, universal GPU). |
| `variants/stacks/` | Optional package sets (dev, security, gaming) staged per edition. |
| `variants/nvidia/` | NVIDIA-variant-only package list. |
| `extras/kali/` | Kali repo source, low-priority pin, curated tools list. |
| `make-kali-key.sh` | Downloads + fingerprint-verifies the Kali archive key (build time). |
| `config/hooks/normal/*.hook.chroot` | Build steps (deploy skel, apps, kali, nvidia, services, cleanup). |
| `config/includes.chroot/` | Files baked into squashfs (populated by `build.sh`). |
| `out/` | Built ISOs. |
