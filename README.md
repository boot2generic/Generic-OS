# Generic-OS

Build custom **Debian 13 (trixie)** installable ISOs with a themed KDE **Plasma 6 /
Wayland** desktop, applications, services, and dotfiles **baked in** — so a fresh
install boots into a fully configured machine and **installs with zero internet**.

The build host (online) pulls the latest software and bakes it into the image;
the resulting ISOs need no network during installation. Targeted at **security
research, development, and gaming**, shipped as selectable editions.

## How it works
The builder uses Debian `live-build` to fully provision a live system, then ships
**Calamares**, which installs by cloning that live filesystem to disk. Anything
present at build time is on the installed system offline — the image *is* the
payload. User dotfiles are baked into `/etc/skel` (copied into each new user's
home at install), and hardware-specific bits (NVIDIA, grub/initramfs) are handled
per-variant. The whole desktop comes from the **`dotfiles/` git submodule**, so
updating dotfiles upstream flows into the ISOs with no manual copying.

## Editions
Each build produces selectable editions (declarative — one file per edition in
`iso/editions/`), across GPU variants `universal` (Mesa; AMD/Intel out of box) and
`nvidia` (driver baked in):

| Edition | Stacks | Kali repo | Kali tools | App tiers | Variants |
|---------|--------|-----------|------------|-----------|----------|
| `everything` | dev + security + gaming | yes (pinned-low) | no | all | universal, nvidia |
| `security` | dev + security | yes (pinned-low) | curated set baked | all | universal |
| `gaming` | dev + gaming | no | no | tier 1 (core) | universal, nvidia |

The Kali repo is pinned to low priority — Debian always wins, and `apt install <tool>`
pulls Kali-only tools on demand without destabilizing the base system.

## Structure
```
Generic-OS/                 ← this project repo
├── iso/                    ← the ISO builder (see iso/README.md)
│   ├── build.sh            ← orchestrator (edition × variant matrix)
│   ├── config.env          ← suite, arch, editions, Kali key pin
│   ├── editions/*.env      ← declarative edition definitions
│   ├── config/             ← live-build package-lists + chroot hooks
│   ├── variants/, extras/  ← stack lists, NVIDIA list, Kali repo files
│   └── out/                ← built ISOs
└── dotfiles/               ← git submodule → boot2generic/dotfiles (branch main)
```

## Prerequisites
A Debian **trixie** host (matches the target suite) with:
```bash
sudo apt install live-build rsync gpg curl
```

## Clone (get the dotfiles submodule too)
```bash
git clone --recurse-submodules <this-repo-url> Generic-OS
# already cloned without submodules?
git submodule update --init --remote dotfiles
```

## Build
**Containerized (recommended)** — keeps the host clean; only a container runtime is
needed (the script installs `podman` if missing). Builds a Debian-trixie image with
the full live-build toolchain, runs the build in a `--privileged --rm` container, and
drops ISOs in `iso/out/`:
```bash
cd iso
sudo ./container-build.sh                 # all editions → iso/out/*.iso
sudo ./container-build.sh security        # one edition
sudo ./container-build.sh clean           # remove container(s), image, build artifacts
```

**On-host** — runs live-build directly (host needs `live-build rsync gpg curl`):
```bash
cd iso
sudo ./build.sh                 # all editions in $EDITIONS → iso/out/*.iso
sudo ./build.sh security        # just one edition (all its variants)
sudo ./build.sh clean           # reset the build tree
```
Output: `iso/out/<suite>-<edition>-<variant>.iso`. Each build **auto-pulls the
latest dotfiles** first (submodule tracks `main`); build from the pinned checkout
with `sudo NO_UPDATE_DOTFILES=1 ./…` (variable *after* `sudo` — its default
`env_reset` strips variables set before it).

## Update the dotfiles
Edit + push in the `dotfiles/` submodule (it's the real `boot2generic/dotfiles`
checkout), then rebuild — the next build pulls your changes. To record the new
dotfiles commit in this project: `git add dotfiles && git commit -m "bump dotfiles"`.

## To Debian 14 later
Change `DEBIAN_SUITE` in `iso/config.env`, then `sudo ./iso/build.sh clean` and rebuild.

## Docs
- [`iso/README.md`](iso/README.md) — builder layout, editions, quick reference.
- [`iso/docs/USER.md`](iso/docs/USER.md) — install from an ISO; what each edition includes.
- [`iso/docs/DEVELOPER.md`](iso/docs/DEVELOPER.md) — architecture, extending, internals, gotchas.
