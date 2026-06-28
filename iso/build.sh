#!/usr/bin/env bash
# Top-level ISO builder. Run from a Debian host matching $DEBIAN_SUITE.
#
#   sudo ./build.sh            # build every edition in $EDITIONS (config.env)
#   sudo ./build.sh security   # build one edition (all its variants)
#   sudo ./build.sh clean      # lb clean + drop synced includes/lists
#
# The dotfiles live in the `dotfiles/` git submodule (sibling of iso/). By
# default each build pulls the latest dotfiles (submodule tracks main) so
# ISOs always reflect the newest pushed dotfiles. Set NO_UPDATE_DOTFILES=1
# to build from whatever is currently checked out.
#
# An edition is defined in editions/<name>.env (stacks, app tiers, Kali
# settings, GPU variants). Output: out/<suite>-<edition>-<variant>.iso
set -euo pipefail

ISO_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$ISO_DIR/.." && pwd)"
REPO_DIR="$PROJECT_DIR/dotfiles"            # the dotfiles git submodule
cd "$ISO_DIR"
# shellcheck source=/dev/null
. ./config.env

[[ $EUID -eq 0 ]] || { echo "build.sh must run as root (live-build needs it)"; exit 1; }
command -v lb >/dev/null || { echo "install live-build: apt install live-build"; exit 1; }

# Ensure the dotfiles submodule is present and (by default) up to date.
update_dotfiles() {
  if [[ ! -e "$REPO_DIR/local_setup.sh" ]]; then
    echo "dotfiles submodule not initialized — run: git -C '$PROJECT_DIR' submodule update --init"
    exit 1
  fi
  if [[ "${NO_UPDATE_DOTFILES:-0}" == 1 ]]; then
    echo "[dotfiles] using checked-out submodule (NO_UPDATE_DOTFILES=1)"
    return 0
  fi
  echo "[dotfiles] pulling latest (submodule tracks main)…"
  git -C "$PROJECT_DIR" submodule update --remote --merge dotfiles \
    || echo "[dotfiles] WARNING: update failed (offline?) — building from checked-out version"
  echo "[dotfiles] at $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
}

LISTS="config/package-lists"
INC="config/includes.chroot"
GENERATED_LISTS="25-gpu-nvidia 30-dev 40-security 50-gaming"

clear_generated_lists() { for l in $GENERATED_LISTS; do rm -f "$LISTS/$l.list.chroot"; done; }
clean() { ./auto/clean || true; rm -rf "$INC/etc" "$INC/usr" "$INC/opt"; clear_generated_lists; }

stack_file() { case "$1" in dev) echo 30-dev;; security) echo 40-security;; gaming) echo 50-gaming;; *) return 1;; esac; }

sync_dotfiles() {
  mkdir -p "$INC/etc" "$INC/usr" "$INC/opt/dotfiles"
  # System drop-ins (/etc, /usr/local) baked verbatim. --delete wipes any
  # stale staged kali/env files from a previous edition; we re-stage below.
  rsync -a --delete "$REPO_DIR/config/system/etc/" "$INC/etc/"
  rsync -a --delete "$REPO_DIR/config/system/usr/" "$INC/usr/"
  rsync -a --delete \
    --exclude='.git' --exclude='bundle/' \
    --exclude='__pycache__/' --exclude='*.pyc' \
    "$REPO_DIR/" "$INC/opt/dotfiles/"
}

stage_lists() {                     # $1=stacks  $2=variant
  local s f
  clear_generated_lists
  for s in $1; do f=$(stack_file "$s") && cp "variants/stacks/$f.list.chroot" "$LISTS/"; done
  [[ "$2" == nvidia ]] && cp variants/nvidia/25-gpu-nvidia.list.chroot "$LISTS/"
  return 0
}

stage_kali() {                      # $1=KALI_REPO  $2=KALI_TOOLS
  [[ "$1" == 1 ]] || return 0
  ./make-kali-key.sh
  install -D -m0644 cache/kali-archive-keyring.gpg "$INC/etc/apt/keyrings/kali-archive-keyring.gpg"
  install -D -m0644 extras/kali/kali.sources       "$INC/etc/apt/sources.list.d/kali.sources"
  install -D -m0644 extras/kali/kali-pin.pref      "$INC/etc/apt/preferences.d/kali-pin"
  [[ "$2" == 1 ]] && install -D -m0644 extras/kali/kali-tools.list "$INC/etc/dotfiles-kali-tools.list"
  return 0
}

stage_env() {                       # $1=edition  $2=app-tiers  $3=kali-tools
  printf 'EDITION=%s\nAPPS_TIERS=%s\nKALI_TOOLS=%s\n' "$1" "${2:-}" "${3:-0}" > "$INC/etc/dotfiles-iso.env"
}

build_one() {                       # $1=edition
  local e="$1" v
  STACKS=""; KALI_REPO=0; KALI_TOOLS=0; APPS_TIERS=""; VARIANTS=""
  # shellcheck source=/dev/null
  . "editions/$e.env"
  for v in $VARIANTS; do
    echo "=== building edition=$e variant=$v (suite=$DEBIAN_SUITE) ==="
    ./auto/clean || true
    sync_dotfiles
    stage_lists "$STACKS" "$v"
    stage_kali "$KALI_REPO" "$KALI_TOOLS"
    stage_env "$e" "$APPS_TIERS" "$KALI_TOOLS"
    EDITION="$e" VARIANT="$v" ./auto/config
    ./auto/build
    mkdir -p out
    mv -f live-image-*.iso "out/${DEBIAN_SUITE}-${e}-${v}.iso"
    echo "=== done: out/${DEBIAN_SUITE}-${e}-${v}.iso ==="
  done
}

case "${1:-}" in
  clean) clean; exit 0 ;;
  "")    update_dotfiles; for e in $EDITIONS; do build_one "$e"; done ;;
  *)     if [[ -f "editions/$1.env" ]]; then update_dotfiles; build_one "$1";
         else echo "unknown edition '$1' (have: $(cd editions && echo *.env | sed 's/\.env//g'))"; exit 1; fi ;;
esac
