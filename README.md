# custom_os — Cyberpunk Debian ISO project

Builds custom Debian 13 (trixie) installable ISOs (Plasma 6, themed, security /
dev / gaming editions) with the dotfiles baked in for a zero-internet install.

## Structure
```
custom_os/                  ← this project repo
├── iso/                    ← the ISO builder (see iso/README.md)
└── dotfiles/               ← git submodule → boot2generic/dotfiles (branch main)
```
The desktop, configs, apps, and provisioner live in the **`dotfiles/` submodule**.
The builder syncs from it, so updating dotfiles upstream flows into the ISOs — no
manual copying.

## Clone (get the dotfiles submodule too)
```bash
git clone --recurse-submodules <this-repo-url> custom_os
# already cloned without submodules?
git submodule update --init --remote dotfiles
```

## Build
```bash
sudo apt install live-build rsync gpg curl        # trixie host
cd iso && sudo ./build.sh                          # all editions → iso/out/*.iso
```
Each build **auto-pulls the latest dotfiles** first (the submodule tracks `main`).
Build offline / from the pinned checkout with `NO_UPDATE_DOTFILES=1 sudo ./build.sh`.

## Update the dotfiles
Edit + push in the `dotfiles/` submodule (it's the real `boot2generic/dotfiles`
checkout), then rebuild — the next build pulls your changes. To record the new
dotfiles commit in this project: `git add dotfiles && git commit -m "bump dotfiles"`.

See [`iso/README.md`](iso/README.md) for editions, layout, and internals.
