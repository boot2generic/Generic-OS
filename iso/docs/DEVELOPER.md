# Developer guide

## Model: bake into squashfs
Calamares installs by **cloning the live filesystem to disk** (`unpackfs`). So
anything present in the live squashfs at build time is on the installed system
with no network. The build is just: provision a Debian live image fully, then
ship it.

```
config.env (EDITIONS) ─▶ build.sh ─▶ for each edition × its variants:
   editions/<e>.env ──▶ sync dotfiles into includes.chroot
                      ─▶ stage stack lists + nvidia list (per variant)
                      ─▶ stage Kali repo/key/pin/tools (if KALI_REPO)
                      ─▶ lb config (codename, areas, edition/variant label)
                      ─▶ lb build ─▶ package-lists install
                                   ─▶ hooks (deploy/apps/kali/nvidia/services)
                                   ─▶ squashfs + Calamares
                                   ─▶ out/<suite>-<edition>-<variant>.iso
```

## Editions
An **edition** is a named composition, defined declaratively in `editions/<name>.env`:

| Key | Meaning |
|-----|---------|
| `STACKS` | space-separated: `dev` `security` `gaming` → `variants/stacks/{30-dev,40-security,50-gaming}` |
| `KALI_REPO` | `1` = stage the pinned-low Kali repo + key (on-demand `apt install`) |
| `KALI_TOOLS` | `1` = also bake the curated `extras/kali/kali-tools.list` |
| `BACKPORTS` | `1` = stage the official Debian backports repo (for gamescope etc.) |
| `APPS_TIERS` | passed to `apps-cli.sh --tier` (empty = all; `1` = core) |
| `VARIANTS` | which GPU variants to build (`universal`, `nvidia`) |

`build.sh` reads `EDITIONS` from `config.env`, sources each edition file, and loops
`edition × VARIANTS`. Build a subset with `./build.sh <edition>`. Add an edition =
create `editions/<name>.env` + add the name to `EDITIONS`. No other changes.

## How dotfiles get baked
The install username is unknown at build time, so user configs go to **`/etc/skel`**
(Calamares copies skel → the new user's home). `build.sh` and the hooks reuse the
existing provisioner instead of reimplementing it:

| Concern | Mechanism |
|---------|-----------|
| User configs (`~/.config`, themes, shell) | `0200-deploy-skel` runs `local_setup.sh deploy` with `HOME=/etc/skel`. |
| Third-party apps (pinned) | `0300-deploy-apps` runs `scripts/apps-cli.sh validate && install`; build host is online so GPG/SHA256 pins are enforced and verified binaries are baked. |
| Shell stack (omz/tpm/starship/nvim) | `0500-terminal-skel` runs `local_setup.sh terminal` into skel. |
| System files (`/etc`, `/usr/local`) | `build.sh` rsyncs `config/system/` into `includes.chroot`. |
| Kali tools (security edition) | `0400-kali-tools` installs `extras/kali/kali-tools.list` from the pinned repo when `KALI_TOOLS=1`. |
| Gaming extras not in stable | `0450-gaming-extras` installs gamescope from backports (`-t <suite>-backports`) and protontricks via pipx (global, `/opt/pipx`). No flatpak. |
| NVIDIA cmdline/initramfs/PM | `0600-nvidia-bake` writes static config (real `nvidia-current*` module names — bare `nvidia` only resolves via an alias conf that doesn't exist until 5025); Calamares regenerates grub+initramfs on the target. |
| NVIDIA glx alternative | `5025-nvidia-glx` re-points glx→nvidia AFTER live-build's stock `5020` hook (which resets it to mesa, stripping the nouveau blacklist / modprobe alias / modules-load / Xorg slave links), then rebuilds the initramfs and hard-verifies the modules embedded. |
| Offline installer | `0860-offline-installer` replaces `calamares-bootloader-config` (upstream apt-installs grub in the target — offline installs otherwise ABORT at the bootloader step) and widens `calamares-sources-final` components to contrib/non-free so baked nvidia/steam packages get updates. |
| Services | `0700-enable-services` `systemctl enable` (never `start` — no systemd in chroot). |
| Identity/cleanup | `9999-cleanup` clears machine-id, ssh host keys, apt cache. |

**Build user:** `local_setup.sh` refuses to run as root and escalates via `sudo`.
Hooks run as root, so `0150-build-user` creates a throwaway `lbbuild` user with NOPASSWD
sudo and makes `/etc/skel` writable; deploy/apps/terminal hooks run the provisioner as
`lbbuild` (via `runuser`), and its internal `sudo` calls escalate normally. `9999-cleanup`
restores skel ownership to root and deletes the user + sudoers drop-in.

## Extending
- **Add an app:** add a block to `../config/apps/apps.toml` (existing manifest). The
  apps hook installs it next build. No ISO changes.
- **Add distro packages:** append to an always-on list in `config/package-lists/`, or to an
  optional stack in `variants/stacks/`. 32-bit (`:i386`) packages go in the `0100-multiarch`
  hook, not a list (lists install before multiarch is enabled).
- **Add a config:** drop it under `../config/`; it flows into skel via `local_setup.sh deploy`.
- **Change what an edition includes:** edit its `editions/<name>.env` (stacks, tiers, Kali, variants).
  `build.sh` copies the named `variants/stacks/*` into `config/package-lists/` per build (non-destructive).
- **Add an edition:** create `editions/<name>.env`, add `<name>` to `EDITIONS` in `config.env`.
- **Add a GPU variant:** add `variants/<name>/` lists and a branch in `build.sh`'s `stage_lists`.
- **Curate Kali tools:** edit `extras/kali/kali-tools.list` (one package per line).
- **Boot menu / bootloader tweaks:** per-file overlays in `config/bootloaders/<name>/`
  replace live-build's templates. We override `isolinux/isolinux.cfg` (BIOS) and
  `grub-pc/config.cfg` (UEFI — grub-efi reuses the grub-pc templates) to auto-boot
  the live entry after **5s** instead of waiting forever, so headless/VM boots work.
- **Branding:** the `0850-branding` hook suppresses KDE's Welcome Center via an
  `Hidden=true` autostart override in `/etc/skel` and rebrands Calamares surfaces
  ("Install Debian" launcher, `branding.desc` product names) to Generic OS.
  `validate-iso.sh` guards both. The ISO volume ID is `GENOS_<EDITION>_<VAR>`
  (uppercased/truncated in `auto/config` to satisfy ISO 9660/Joliet label rules).

## Kali repo (security & everything editions)
- `make-kali-key.sh` downloads `archive-keyring.gpg` and **hard-fails unless the pinned
  `KALI_KEY_FPR` is present** (same discipline as the repo's other pinned installers).
  Update `KALI_KEY_FPR` in `config.env` when Kali rotates keys.
- `build.sh` stages `extras/kali/kali.sources` (deb822, `Signed-By` the keyring),
  `kali-pin.pref` (`Pin-Priority: 100`), and the verified keyring into `includes.chroot`.
- **Pin priority 100** means Debian (500) always wins for shared packages — no
  "frankendebian". Kali-only tools still install via `apt install <tool>`. The repo +
  pin are baked, so this works on the installed system too.
- `0400-kali-tools` installs the curated list per-tool (best-effort, `apt-mark manual`).

## Parameterization / Debian 14
Change `DEBIAN_SUITE` in `config.env`, then `sudo ./build.sh clean`. Re-pin apps for
the new suite (`../scripts/refresh-pins.sh`) and verify any deb822 `.sources` under
`../config/system/etc/apt` that hardcode a codename.

## Containerized build
`container-build.sh` builds a `debian:trixie` image (inline Containerfile) with the
live-build toolchain, bind-mounts the project at `/project`, and runs `./build.sh` in a
`--privileged --rm` container — so the host needs only podman/docker (auto-installed)
and the toolchain/version is reproducible regardless of host. `--privileged` is required
(live-build does mount/debootstrap/loop). Inside the container there's no `$SUDO_USER`,
so the dotfiles pull runs as root over HTTPS with `safe.directory '*'` (set in the
image). ISOs land in the bind-mounted `out/` and are chowned back to the invoker.
`container-build.sh clean` removes the container(s), image, and host build artifacts.
Note: this does NOT change package availability — same trixie repos as an on-host build.

## Gotchas
- Build on a host matching `DEBIAN_SUITE` (or use `container-build.sh`, which pins it).
- **The squashfs must contain grub** (`grub-efi`, `grub-efi-amd64`, `grub-efi-amd64-signed`,
  `grub-pc-bin`, `grub2-common`, `shim-signed`, `efibootmgr`, `keyutils` in `00-base`). The
  *live ISO* boots via live-build's own loader, but **Calamares installs the target's
  bootloader from packages in the squashfs** — without them the installed disk is unbootable
  (and `/etc/default/grub`, the NVIDIA-cmdline target, won't exist). `grub-efi`/`grub-efi-amd64`
  specifically make the bootloader helper's `apt-get install grub-efi` a no-op so OFFLINE
  installs don't abort (`grub-pc` conflicts with `grub-efi-amd64` and stays unbaked; the
  0860-patched helper covers BIOS installs via the baked `grub-pc-bin`). `validate-iso.sh`
  checks all of this.
- **Validate package availability with `./check-packages.sh` before building** — it
  checks every list package has a real install *Candidate* (`apt-cache show` is NOT
  enough; it succeeds for uninstallable packages and will let a build fail late).
- **Package sourcing policy (no flatpak):** if a package isn't in Debian stable, source it
  natively — official **backports** (`BACKPORTS=1`, e.g. gamescope), the **Kali** repo
  (security tools, e.g. radare2), or **pipx** for pure-Python upstream CLIs (e.g.
  protontricks). Don't drop to flatpak. Backports/Kali packages are installed via hooks
  (not package-lists), so `check-packages.sh` skips them.
- Declare apt packages in package-lists; hook-installed packages are `apt-mark manual`'d
  to dodge live-build pruning ([Bug#1062641](https://bugs.debian.org/1062641)).
- Never `systemctl start` in a hook. grub/initramfs regen happens on the target via Calamares.
- **Secure Boot + nvidia variant:** DKMS signs the modules with an auto-generated MOK
  (`/var/lib/dkms/mok.{key,pub}`, generated at build — note the same private key ships in
  every install of that build), but no firmware trusts it → modules won't load with Secure
  Boot on. Either disable Secure Boot, or enroll post-install: `mokutil --import
  /var/lib/dkms/mok.pub` + reboot into the MOK manager (`mokutil` is in `00-base`).
  Mesa/AMD/Intel are unaffected.
- Calamares offline flow comes from `calamares-settings-debian`; to rebrand, ship an
  `includes.installer/etc/calamares/` with a complete `settings.conf` + `branding/`.
- **Kali during build:** the build host has internet, so the pinned Kali repo + curated
  tools install at build time. `kali-rolling` is large — expect a slower `apt update`.
  Pin priority 100 prevents Kali from dragging its rolling base into the image.

## Build speed
A warm-cache build is ~19–25m per variant (measured on the i7-10610U build laptop:
≈11.5m package install, ≈3.5m hooks, ≈3–4m squashfs zstd-12, ≈1m ISO). A *cold* build
adds package **download** (~1.5–2 GB) — that download is the "~1 hour" case.

**Throttling trap:** on a laptop, a power-limited/battery run can slow mksquashfs ~10×
(one observed run: 32m for the squashfs stage alone; the same machine benchmarks
zstd-12 at ~47 MB/s ≈ 4m when unthrottled). Build on AC with the performance profile,
and expect back-to-back variants to run warmer/slower than the first.

Two knobs cut it further:
- **`FAST=1`** (or `SQUASHFS_LEVEL=3`) — drops squashfs to level 3 for dev iteration:
  mksquashfs ~1m instead of ~4m, at the cost of a bigger ISO. An explicit `SQUASHFS_LEVEL`
  always wins. Leave the default (12) for release ISOs.
  `sudo FAST=1 ./container-build.sh gaming`
- **`APT_PROXY`** (apt-cacher-ng) — reuse downloaded .debs across editions, rebuilds, and
  `purge`, turning cold builds warm and fetching the shared base once for an all-editions
  run. `sudo ./extras/apt-cacher.sh` installs+starts it and prints the value:
  `sudo APT_PROXY=http://localhost:3142 ./container-build.sh` (auto-adds `--network host`).
  `auto/config` drops the mirror to http so the cache can see the traffic — apt still
  GPG-verifies every package, so integrity is unchanged.

Put the knobs **after** `sudo` (`sudo FAST=1 …`), not before it: sudo's default
`env_reset` strips variables set before `sudo`, so `FAST=1 sudo …` silently does
nothing. Command-line assignments after `sudo` are passed through.

The `cache/` dir already survives `clean` (only `purge` wipes it), so same-edition rebuilds
are warm without a proxy. Recommends are intentionally left ON (Plasma relies on them); a
`--apt-recommends false` pass would be the biggest further cut but needs functional testing.

## Verify a build
Automated: `./validate-iso.sh` (structure; add `sudo` for content checks inside the
squashfs) and `./validate-boot.sh` (boots each ISO in QEMU, screenshots the desktop,
runs in-guest checks via the guest agent). Both warn when an ISO in `out/` predates a
build-source change — rebuild before trusting FAILs. `validate-boot.py` boots the
extracted kernel directly by default; pass `--firmware bios` or `--firmware uefi`
(needs `ovmf`) to boot through the real bootloader + 5s menu auto-boot instead.
CI (`.github/workflows/ci.yml`) shellchecks the scripts and verifies every package
in the lists still has an install candidate on the target suite.

Manual:
1. `sudo ./build.sh security` → `out/trixie-security-universal.iso` (or `./build.sh` for all).
2. Boot it in a VM with **networking disabled** (`qemu … -nic none`); confirm Plasma live
   session + Calamares launch.
3. Run Calamares to completion offline; reboot into the installed system.
4. Confirm per edition: themed Plasma + zsh default everywhere; security → nmap/wireshark +
   `apt-cache policy metasploit-framework` shows the pinned Kali repo; gaming → Steam/Lutris;
   everything → all of the above. Run `../local_setup.sh validate`.
5. nvidia variant on NVIDIA hardware: `nvidia-smi` works, KMS active, Wayland session OK.
