# User guide

A ready-to-use Debian 13 KDE Plasma desktop, themed and fully configured. No
internet needed during installation.

## Pick your ISO (`out/`)
ISOs are named `trixie-<edition>-<gpu>.iso`.

**Edition** (what's installed):
- **`everything`** — dev + security + gaming + all apps. The Kali repo is present
  (for `apt install <tool>`) but only a light set of security tools is preinstalled.
- **`security`** — security research: developer tooling + security tools + the Kali
  repo with a curated set of common Kali tools (metasploit, burpsuite, ffuf, …) baked in.
- **`gaming`** — gaming + developer tooling + core apps. No security tooling.

**GPU** (`<gpu>`):
- **`universal`** — AMD or Intel graphics. Works out of the box.
- **`nvidia`** — NVIDIA graphics. Driver is preinstalled. (Not built for `security`.)

> NVIDIA + Secure Boot: if the desktop boots to a black screen, disable Secure
> Boot in your firmware (the preinstalled driver is unsigned). Or use the
> universal ISO on the integrated GPU first.

## Install
1. Write the ISO to a USB stick:
   - Linux: `sudo dd if=out/trixie-nvidia.iso of=/dev/sdX bs=4M status=progress conv=fsync`
   - Or use Etcher / Ventoy / Rufus.
2. Boot from the USB (you may need to disable Secure Boot — see above).
3. The live desktop loads. Launch **Install** (Calamares) from the desktop.
4. Follow the prompts: language → disk → **create your user** → install. No network required.
5. Reboot, remove the USB. Log in — your desktop is fully themed and ready.

## What's included (all editions)
- **Desktop:** KDE Plasma 6 (Wayland), cyberpunk theme, i3-style shortcuts
  (Meta+Return terminal, Meta+1–4 desktops, Meta+/ cheatsheet).
- **Terminal:** zsh (default shell) + oh-my-zsh, tmux, neovim, starship, alacritty.
- **Development:** Node, Python, clang/gdb, build tools, direnv.

By edition, additionally:
- **security / everything:** nmap, wireshark, tcpdump, radare2, binwalk, john, hashcat,
  sqlmap, aircrack-ng, hydra, gobuster — plus the **Kali repo** (security bakes in
  metasploit, burpsuite, ffuf, seclists, and more).
- **gaming / everything:** Steam, Lutris, Wine, GameMode, MangoHud, gamescope.
- **Apps:** KeePassXC, browsers, and (everything/security) Signal, Obsidian, Thunderbird,
  Syncthing, etc. — see `config/apps/apps.toml`.

## First steps after install
- **Connect to network** (NetworkManager tray applet) — needed only now, for updates.
- **Updates:** `sudo apt update && sudo apt full-upgrade`.
- **More Kali tools** (security/everything): the Kali repo is preconfigured and pinned so
  Debian stays primary — install any tool on demand with `sudo apt install <tool>`
  (e.g. `sudo apt install ghidra wpscan`).
- **Per-machine tweaks:** drop overrides in `~/.config/dotfiles-local/` (see main README).

## Help
- Hotkey cheatsheet: press **Meta + /**.
- Health check: `~/path/to/dotfiles/local_setup.sh validate` or `scripts/dotfiles-doctor.sh`.
