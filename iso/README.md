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
```bash
sudo apt install live-build rsync gpg curl    # on a trixie host
cd iso
sudo ./build.sh                # build every edition in $EDITIONS → out/*.iso
sudo ./build.sh security       # build just one edition (all its variants)
```
Default build produces 5 ISOs: `everything`×{universal,nvidia}, `security`×{universal},
`gaming`×{universal,nvidia}. Output: `out/<suite>-<edition>-<variant>.iso`.

Update the desktop: edit anything under `../config/` or `../config/apps/apps.toml`,
then re-run `sudo ./build.sh`.

## Editions
| Edition | Stacks | Kali repo | Kali tools baked | App tiers | Variants |
|---------|--------|-----------|------------------|-----------|----------|
| `everything` | dev + security + gaming | yes (pinned-low) | no | all | universal, nvidia |
| `security` | dev + security | yes (pinned-low) | curated top set | all | universal |
| `gaming` | dev + gaming | no | no | tier 1 (core) | universal, nvidia |

Edit an edition, or add a new one, by editing/creating `editions/<name>.env` and
listing it in `EDITIONS` (config.env). See [`docs/DEVELOPER.md`](docs/DEVELOPER.md).

## Docs
- [`docs/USER.md`](docs/USER.md) — install from the ISO and what you get.
- [`docs/DEVELOPER.md`](docs/DEVELOPER.md) — architecture, how to extend, internals.

## Layout
| Path | Purpose |
|------|---------|
| `config.env` | Build parameters (suite, arch, editions list, Kali key pin). |
| `editions/*.env` | Declarative edition definitions (stacks, tiers, Kali, variants). |
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
