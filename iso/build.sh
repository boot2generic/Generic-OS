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

# --- progress / logging helpers -------------------------------------------
if [[ -t 1 ]]; then
  c_b=$'\033[1;36m'; c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_0=$'\033[0m'
else
  c_b=; c_g=; c_y=; c_0=
fi
ts()   { date +%H:%M:%S; }
say()  { printf '%s[%s]%s %s\n' "$c_b" "$(ts)" "$c_0" "$*"; }
ok()   { printf '%s[%s] ✓ %s%s\n' "$c_g" "$(ts)" "$*" "$c_0"; }
warn() { printf '%s[%s] ! %s%s\n' "$c_y" "$(ts)" "$*" "$c_0"; }

# Ensure the dotfiles submodule is present and (by default) up to date.
update_dotfiles() {
  if [[ ! -e "$REPO_DIR/local_setup.sh" ]]; then
    echo "dotfiles submodule not initialized — run: git -C '$PROJECT_DIR' submodule update --init"
    exit 1
  fi
  if [[ "${NO_UPDATE_DOTFILES:-0}" == 1 ]]; then
    say "dotfiles: using checked-out submodule (NO_UPDATE_DOTFILES=1)"
    return 0
  fi
  # Run git as the invoking user: the repo is user-owned (avoids git's
  # "dubious ownership" refusal under sudo) and uses that user's config.
  # GIT_TERMINAL_PROMPT=0 → never block on a credential prompt.
  local git_as=(env GIT_TERMINAL_PROMPT=0 git)
  [[ -n "${SUDO_USER:-}" ]] && git_as=(sudo -u "$SUDO_USER" env GIT_TERMINAL_PROMPT=0 git)

  # Pull over HTTPS instead of the configured SSH URL. SSH under sudo HANGS:
  # sudo strips SSH_AUTH_SOCK (no agent) and the BatchMode env, so git's ssh
  # blocks on a host-key/auth prompt until the timeout fires. The repo is
  # public, so HTTPS needs no keys/agent and can't prompt. .gitmodules is left
  # untouched (clones still use SSH); we only override the URL for this fetch.
  local url https
  url=$(git config -f "$PROJECT_DIR/.gitmodules" submodule.dotfiles.url 2>/dev/null || true)
  https=$(printf '%s' "$url" | sed -E 's#^git@github\.com:#https://github.com/#; s#^ssh://git@github\.com/#https://github.com/#')
  case "$https" in
    https://*) ;;
    *) warn "can't derive an https URL for dotfiles ($url) — using checked-out version"; return 0 ;;
  esac

  say "dotfiles: pulling latest over https (≤60s; falls back to checked-out)…"
  "${git_as[@]}" -C "$REPO_DIR" checkout -q main 2>/dev/null || true
  if timeout 60 "${git_as[@]}" -C "$REPO_DIR" \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
        fetch --quiet "$https" main 2>/dev/null \
     && "${git_as[@]}" -C "$REPO_DIR" merge --ff-only --quiet FETCH_HEAD 2>/dev/null; then
    ok "dotfiles at $("${git_as[@]}" -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
  else
    warn "dotfiles update skipped (offline/diverged) — building from checked-out version"
  fi
}

LISTS="config/package-lists"
INC="config/includes.chroot"
GENERATED_LISTS="25-gpu-nvidia 30-dev 40-security 50-gaming"

clear_generated_lists() { for l in $GENERATED_LISTS; do rm -f "$LISTS/$l.list.chroot"; done; }
clean() { ./auto/clean || true; rm -rf "${INC:?}/etc" "${INC:?}/usr" "${INC:?}/opt"; clear_generated_lists; }

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

stage_backports() {                 # $1=BACKPORTS
  [[ "$1" == 1 ]] || return 0
  # Official Debian backports (no key/pin needed — debian-archive-keyring +
  # apt's auto NotAutomatic pin). Codename templated from DEBIAN_SUITE.
  mkdir -p "$INC/etc/apt/sources.list.d"
  sed "s/@SUITE@/${DEBIAN_SUITE}/g" extras/backports/backports.sources.in \
    > "$INC/etc/apt/sources.list.d/backports.sources"
  return 0
}

stage_env() {                       # $1=edition $2=app-tiers $3=kali-tools $4=backports $5=gaming
  printf 'EDITION=%s\nAPPS_TIERS=%s\nKALI_TOOLS=%s\nBACKPORTS=%s\nGAMING=%s\nSUITE=%s\n' \
    "$1" "${2:-}" "${3:-0}" "${4:-0}" "${5:-0}" "$DEBIAN_SUITE" > "$INC/etc/dotfiles-iso.env"
}

build_one() {                       # $1=edition
  local e="$1" v gaming=0
  STACKS=""; KALI_REPO=0; KALI_TOOLS=0; BACKPORTS=0; APPS_TIERS=""; VARIANTS=""
  # shellcheck source=/dev/null
  . "editions/$e.env"
  [[ " $STACKS " == *" gaming "* ]] && gaming=1
  for v in $VARIANTS; do
    local t0=$SECONDS
    printf '%s\n%s═══ %s / %s  (suite=%s)  stacks:[%s] kali:%s ═══%s\n' \
      "" "$c_b" "$e" "$v" "$DEBIAN_SUITE" "$STACKS" "$KALI_REPO" "$c_0"
    say "[1/5] cleaning previous build state…";            ./auto/clean || true
    say "[2/5] syncing dotfiles into chroot tree…";        sync_dotfiles
    say "[3/5] staging package lists + Kali/backports/extras…"; stage_lists "$STACKS" "$v"; stage_kali "$KALI_REPO" "$KALI_TOOLS"; stage_backports "$BACKPORTS"; stage_env "$e" "$APPS_TIERS" "$KALI_TOOLS" "$BACKPORTS" "$gaming"
    say "[4/5] lb config (resolving live-build tree)…";    EDITION="$e" VARIANT="$v" ./auto/config
    say "[5/5] lb build — the long stage: bootstrap → packages → hooks → squashfs → ISO"
    say "      (progress streams below + heartbeat every 30s; full log: iso/build.log)"
    ./auto/build
    mkdir -p out
    local iso="out/${DEBIAN_SUITE}-${e}-${v}.iso"
    mv -f live-image-*.iso "$iso"
    # Built under sudo → root-owned; hand back to the invoking user.
    [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$iso" 2>/dev/null || true
    ok "$e/$v built in $(( (SECONDS-t0)/60 ))m$(( (SECONDS-t0)%60 ))s → $iso"
  done
}

case "${1:-}" in
  clean) clean; exit 0 ;;
  "")    update_dotfiles; for e in $EDITIONS; do build_one "$e"; done ;;
  *)     if [[ -f "editions/$1.env" ]]; then update_dotfiles; build_one "$1";
         else echo "unknown edition '$1' (have: $(cd editions && echo *.env | sed 's/\.env//g'))"; exit 1; fi ;;
esac
