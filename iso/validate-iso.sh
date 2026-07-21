#!/usr/bin/env bash
# Validate built Generic-OS ISOs: structure (bootable image + squashfs + EFI)
# and contents (right packages/configs per edition, build-only cruft removed).
#
#   ./validate-iso.sh                    # all iso/out/*.iso  (structural only)
#   sudo ./validate-iso.sh               # + content checks (mounts the squashfs)
#   sudo ./validate-iso.sh a.iso b.iso   # specific ISOs
#   ./validate-iso.sh --boot a.iso       # boot one in QEMU afterwards (manual look)
#
# Structural checks need no root. Content checks mount the ISO + its squashfs,
# which needs root — run the whole script with sudo to include them.
set -uo pipefail
cd "$(dirname "$0")" || exit 2

# Tee everything to a log so results can be shared/reviewed. Colors are only
# emitted to an interactive terminal, so the log file stays clean plain text.
LOGFILE="${VALIDATE_LOG:-validate.log}"
exec > >(tee "$LOGFILE") 2>&1
echo "Generic-OS ISO validation — $(date)"
echo "(full log: $(pwd)/$LOGFILE)"

if [ -t 1 ]; then C_G=$'\033[1;32m'; C_R=$'\033[1;31m'; C_Y=$'\033[1;33m'; C_0=$'\033[0m'
else C_G=; C_R=; C_Y=; C_0=; fi
PASS=0; FAIL=0; WARN=0
p(){ printf '  %s[PASS]%s %s\n' "$C_G" "$C_0" "$*"; PASS=$((PASS+1)); }
f(){ printf '  %s[FAIL]%s %s\n' "$C_R" "$C_0" "$*"; FAIL=$((FAIL+1)); }
w(){ printf '  %s[WARN]%s %s\n' "$C_Y" "$C_0" "$*"; WARN=$((WARN+1)); }
have(){ command -v "$1" >/dev/null 2>&1; }

# Is package $2 installed in the squashfs rooted at $1 ? -> prints y/n
pkg_ok(){
  awk -v pkg="$2" 'BEGIN{RS="";FS="\n"}
    { p=0; i=0; for(n=1;n<=NF;n++){ if($n=="Package: "pkg)p=1; if($n ~ /^Status: .* ok installed$/)i=1 }
      if(p){ found=1; print (i?"y":"n"); exit } }
    END{ if(!found) print "n" }' "$1/var/lib/dpkg/status" 2>/dev/null
}
chk_pkg(){  # $1=root $2=pkg  [$3=label]  — required (FAIL if missing)
  [ "$(pkg_ok "$1" "$2")" = y ] && p "package installed: ${3:-$2}" || f "package MISSING: ${3:-$2}"; }
chk_pkg_opt(){  # best-effort install (Kali tools / Steam hook): WARN, not FAIL
  [ "$(pkg_ok "$1" "$2")" = y ] && p "package installed: ${3:-$2}" || w "best-effort package not installed: ${3:-$2} (install on demand later)"; }
chk_file(){ [ -s "$1/$2" ] && p "present: /$2"        || f "MISSING/empty: /$2"; }
chk_absent(){ [ ! -e "$1/$2" ] && p "removed (build-only): /$2" || f "should NOT be on image: /$2"; }
chk_grep(){ grep -q "$3" "$1/$2" 2>/dev/null && p "$2 contains '$3'" || f "$2 missing '$3'"; }

structural(){  # $1=iso
  local iso="$1" sz
  sz=$(stat -c%s "$iso" 2>/dev/null || echo 0)
  [ "$sz" -gt $((1024*1024*1024)) ] && p "size $(numfmt --to=iec "$sz")" || f "size suspicious: $(numfmt --to=iec "$sz")"
  local ft; ft=$(file -b "$iso")
  echo "$ft" | grep -q 'ISO 9660'                 && p "ISO 9660 filesystem"        || f "not an ISO 9660 image ($ft)"
  echo "$ft" | grep -qiE 'boot sector|bootable'   && p "BIOS-bootable (MBR/hybrid)" || w "no MBR boot sector in 'file' output"
  if have xorriso; then
    local et; et=$(xorriso -indev "$iso" -report_el_torito plain 2>&1)
    echo "$et" | grep -qiE 'El Torito|boot image' && p "El Torito boot catalog present" || w "no El Torito catalog reported"
  fi
}

content(){  # $1=iso $2=edition $3=variant
  local iso="$1" ed="$2" var="$3" mnt sq sqfs
  if [ "$(id -u)" != 0 ]; then w "not root — skipping content checks (re-run: sudo $0)"; return; fi
  mnt=$(mktemp -d); sq=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "umount '$sq' 2>/dev/null||true; umount '$mnt' 2>/dev/null||true; rmdir '$sq' '$mnt' 2>/dev/null||true" RETURN
  mount -o loop,ro "$iso" "$mnt" 2>/dev/null || { f "could not mount ISO"; return; }
  ls "$mnt"/EFI/boot/boot*.efi >/dev/null 2>&1 && p "UEFI boot image (/EFI/boot/*.efi)" || w "no /EFI/boot/*.efi (UEFI boot may be unavailable)"
  sqfs=$(find "$mnt" -name 'filesystem.squashfs' 2>/dev/null | head -1)
  [ -n "$sqfs" ] && p "/live/filesystem.squashfs present" || { f "squashfs missing from ISO"; return; }
  mount -o loop,ro "$sqfs" "$sq" 2>/dev/null || { f "could not mount squashfs (kernel zstd support?)"; return; }

  # --- common to every edition ---
  chk_pkg "$sq" plasma-desktop "Plasma desktop"
  chk_pkg "$sq" sddm; chk_pkg "$sq" zsh; chk_pkg "$sq" tmux; chk_pkg "$sq" neovim
  chk_pkg "$sq" alacritty; chk_pkg "$sq" calamares "Calamares installer"
  # Installability: Calamares installs the target's bootloader using grub
  # packages from THIS squashfs. If they're absent, the installed system won't
  # boot (and /etc/default/grub — the NVIDIA cmdline target — won't exist).
  chk_pkg "$sq" grub2-common "grub2-common (update-grub for the install)"
  # calamares-bootloader-config apt-installs grub-efi in the OFFLINE target:
  # if it isn't already baked, every UEFI install FAILS at the bootloader step
  # (observed live in the boot harness). Hard requirement, not a warning.
  chk_pkg "$sq" grub-efi-amd64 "grub-efi-amd64 (offline UEFI bootloader step)"
  chk_pkg "$sq" grub-efi "grub-efi metapackage (bootloader-config no-op)"
  chk_pkg "$sq" keyutils "keyutils (offline LUKS bootloader step)"
  if grep -q 'offline-safe' "$sq/usr/share/calamares/helpers/calamares-bootloader-config" 2>/dev/null; then
    p "calamares-bootloader-config is the offline-safe version (0860)"
  else
    f "calamares-bootloader-config NOT patched (0860 hook) — offline installs abort at bootloader"
  fi
  # sources-final writes the installed sources.list: without contrib/non-free
  # the shipped nvidia/steam packages never receive updates post-install.
  if grep -q 'main contrib non-free non-free-firmware' "$sq/usr/share/calamares/helpers/calamares-sources-final" 2>/dev/null; then
    p "calamares-sources-final includes contrib + non-free components"
  else
    f "calamares-sources-final still writes 'main non-free-firmware' only (nvidia/steam updates unavailable post-install)"
  fi
  chk_file "$sq" etc/default/grub
  chk_file "$sq" etc/skel/.zshrc
  # Login shell actually zsh for created accounts (adduser = live user path).
  chk_grep "$sq" etc/adduser.conf 'DSHELL=/usr/bin/zsh'
  # Calamares path: 3.3 reads user.shell (nested), NOT top-level userShell —
  # an ISO without the nested key installs users with /bin/bash. Locate the
  # file the way Calamares does (/etc/calamares wins over /usr/share).
  local ucf
  ucf=$(find "$sq/etc/calamares" "$sq/usr/share/calamares" -name users.conf 2>/dev/null | head -1)
  if [ -n "$ucf" ] && grep -A3 '^user:' "$ucf" | grep -q 'shell: */usr/bin/zsh'; then
    p "calamares users.conf sets nested user.shell=/usr/bin/zsh"
  else
    f "calamares users.conf missing nested 'user: shell: /usr/bin/zsh' (installed users get bash)"
  fi
  # Tier-1 app bake sentinel: 0300 is best-effort, so its total failure only
  # WARNs in the build log — catch it here too. keepassxc is in every edition.
  chk_pkg_opt "$sq" keepassxc "keepassxc (tier-1 app bake sentinel)"
  chk_file "$sq" etc/skel/.config/kdeglobals
  chk_file "$sq" etc/skel/.config/autostart/conky.desktop      # regression guard (the old 0200 bug)
  chk_file "$sq" etc/skel/.config/alacritty/alacritty.toml
  # Branding (0850 hook): Welcome Center suppressed; Calamares says Generic OS.
  # The kded6rc module disable is the one that actually works on trixie (the
  # xdg-autostart override is belt-and-braces — plasma-welcome starts via kded).
  # Live session identity (0800): named live user + SDDM autologin agree.
  chk_grep "$sq" etc/live/config.conf.d/zz-username.conf 'LIVE_USERNAME="generic"'
  chk_grep "$sq" etc/sddm.conf.d/zz-live-autologin.conf 'User=generic'
  # Anchor autoload=false to the module section. The plugin id kded6 actually
  # honours is "kded_plasma-welcome" (library basename, kded_ prefix NOT
  # stripped) — verified at runtime: with only [Module-plasma-welcome] the
  # Welcome Center still autoloads. Require the working section.
  if grep -A2 '^\[Module-kded_plasma-welcome\]' "$sq/etc/skel/.config/kded6rc" 2>/dev/null \
     | grep -q 'autoload=false'; then
    p "kded6rc disables kded_plasma-welcome module"
  else
    f "kded6rc missing [Module-kded_plasma-welcome] autoload=false (Welcome Center will autostart)"
  fi
  chk_file "$sq" etc/skel/.config/autostart/org.kde.plasma-welcome.desktop
  chk_grep "$sq" etc/skel/.config/autostart/org.kde.plasma-welcome.desktop 'Hidden=true'
  # The check that actually decides at session start: LastSeenVersion in
  # plasma-welcomerc must be far-future or the kded module launches the app.
  chk_grep "$sq" etc/skel/.config/plasma-welcomerc 'LastSeenVersion=999'
  chk_file "$sq" etc/skel/.config/wallpaper/wallpaper.png   # regression guard (deploy-abort bug)
  # HOME=/etc/skel leakage guard: autostart Exec lines must not point at the
  # skel copies (users' own config edits would silently do nothing) — and must
  # use '~/' not '$HOME/': the xdg-autostart generator mangles $ into \$ and
  # every wrapped entry then dies with exit 127 at login (verified live).
  if grep -l '^Exec=.*/etc/skel/' "$sq"/etc/skel/.config/autostart/*.desktop >/dev/null 2>&1; then
    f "skel autostart .desktop Exec still hardcodes /etc/skel (0200 rewrite missing)"
  elif grep -l '^Exec=.*\$HOME' "$sq"/etc/skel/.config/autostart/*.desktop >/dev/null 2>&1; then
    f "skel autostart Exec uses \$HOME (breaks under systemd xdg generator — use ~/)"
  else
    p "skel autostart Exec lines are per-user (~/ resolved)"
  fi
  local bd; bd=$(find "$sq/etc/calamares" "$sq/usr/share/calamares" -name branding.desc 2>/dev/null | head -1)
  if [ -n "$bd" ]; then
    grep -q 'Generic OS' "$bd" && p "Calamares branding says Generic OS" || f "Calamares branding.desc still says Debian"
  else
    w "no Calamares branding.desc found in squashfs"
  fi
  [ -f "$sq/etc/machine-id" ] && [ ! -s "$sq/etc/machine-id" ] && p "machine-id blanked (fresh per install)" || w "machine-id not empty"
  grep -q '^lbbuild:' "$sq/etc/passwd" 2>/dev/null && f "build user 'lbbuild' still present" || p "build user removed"
  chk_absent "$sq" etc/sudoers.d/lbbuild
  chk_absent "$sq" etc/apt/apt.conf.d/90dotfiles-build
  chk_absent "$sq" etc/dpkg/dpkg.cfg.d/force-unsafe-io
  chk_absent "$sq" etc/dotfiles-iso.env

  # --- security / everything ---
  case " $ed " in *" security "*|*everything*)
    chk_file "$sq" etc/apt/sources.list.d/kali.sources
    chk_pkg "$sq" nmap; chk_pkg "$sq" wireshark ;;
  esac
  [ "$ed" = security ] && chk_pkg_opt "$sq" metasploit-framework "Kali: metasploit (baked, best-effort)"

  # --- gaming / everything ---  (mangohud is a list package = required;
  #  steam-installer is installed by the 0100 hook = best-effort)
  case "$ed" in gaming|everything)
    chk_pkg_opt "$sq" steam-installer "Steam"; chk_pkg "$sq" mangohud ;;
  esac

  # --- nvidia variant ---
  if [ "$var" = nvidia ]; then
    chk_pkg "$sq" nvidia-driver "NVIDIA driver"
    chk_grep "$sq" etc/default/grub 'nvidia-drm.modeset=1'
    # glx alternative must point at nvidia — live-build's stock 5020 hook
    # resets it to mesa-diverted, which strips the nouveau blacklist + modprobe
    # alias + modules-load slave links (driver dormant on real hardware).
    # The 5025 hook re-points it; these catch a regression.
    if [ "$(readlink "$sq/etc/alternatives/glx" 2>/dev/null)" = /usr/lib/nvidia ]; then
      p "glx alternative -> /usr/lib/nvidia"
    else
      f "glx alternative is '$(readlink "$sq/etc/alternatives/glx" 2>/dev/null || echo none)' (want /usr/lib/nvidia — 5025 hook)"
    fi
    [ -L "$sq/etc/modprobe.d/nvidia-blacklists-nouveau.conf" ] \
      && p "nouveau blacklisted (/etc/modprobe.d/nvidia-blacklists-nouveau.conf)" \
      || f "nouveau NOT blacklisted (glx slave link missing)"
    [ -L "$sq/etc/modprobe.d/nvidia.conf" ] \
      && p "nvidia modprobe alias conf present" \
      || f "/etc/modprobe.d/nvidia.conf missing (modprobe nvidia won't resolve)"
    chk_grep "$sq" etc/initramfs-tools/modules 'nvidia-current'
    # The live initrd must EMBED the driver (bare names silently resolve to
    # nothing; nouveau then owns the GPU from early boot).
    #
    # NO PIPES here: this script runs `set -o pipefail`, the listing is ~3MB,
    # and `… | grep -q` exits at the first match — the writer then dies with
    # SIGPIPE (141), pipefail turns that into pipeline failure, and the check
    # false-FAILed twice against demonstrably good ISOs. Capture to a
    # variable, then pattern-match in pure shell.
    if have lsinitramfs; then
      local initrd_ls initrd_err
      initrd_err=$(mktemp)
      initrd_ls=$(lsinitramfs "$mnt/live/initrd.img" 2>"$initrd_err")
      case "$initrd_ls" in
        *nvidia-current*.ko*)
          p "live initrd embeds nvidia-current modules" ;;
        "")
          w "could not LIST the live initrd ($(tail -1 "$initrd_err" 2>/dev/null | cut -c1-70)) — module check inconclusive, re-run" ;;
        *)
          f "live initrd has NO nvidia-current modules (initramfs built before 5025?)" ;;
      esac
      rm -f "$initrd_err"
    else
      w "lsinitramfs not available — initrd nvidia-module check skipped"
    fi
  fi
}

boot(){  # $1=iso  (manual eyeball; proves bootloader+kernel+live system come up offline)
  have qemu-system-x86_64 || { echo "install qemu: sudo apt install qemu-system-x86 ovmf"; return 1; }
  local bios=""; [ -f /usr/share/OVMF/OVMF_CODE.fd ] && bios="-bios /usr/share/OVMF/OVMF_CODE.fd"  # UEFI if available
  echo ">> Booting $1 in QEMU with NO network ('-nic none'). Watch for the Plasma live desktop; launch 'Install' to test Calamares. Close the window when done."
  # shellcheck disable=SC2086
  qemu-system-x86_64 -enable-kvm -m 6144 -smp 4 -cdrom "$1" -nic none -boot d $bios
}

# ---- args ----
BOOT_ISO=""
ARGS=()
while [ $# -gt 0 ]; do case "$1" in
  --boot) BOOT_ISO="${2:-}"; shift 2 ;;
  *) ARGS+=("$1"); shift ;;
esac; done
[ "${#ARGS[@]}" -gt 0 ] || ARGS=(out/*.iso)

have file || { echo "need 'file' (sudo apt install file)"; exit 1; }
have xorriso || w "xorriso not installed — El Torito check skipped (sudo apt install xorriso)"

overall=0
for iso in "${ARGS[@]}"; do
  [ -f "$iso" ] || { echo "== $iso =="; f "not found"; overall=1; continue; }
  base=$(basename "$iso" .iso)              # trixie-<edition>-<variant>
  ed=$(echo "$base" | cut -d- -f2); var=$(echo "$base" | cut -d- -f3)
  echo; echo "== $(basename "$iso")  (edition=$ed variant=$var) =="
  # A FAIL against an ISO built from older source is expected noise (e.g. a
  # package added to the lists since) — flag it so results aren't misread.
  # Generated staging copies (25/30/40/50 + live, re-cp'd into package-lists
  # during EVERY build) are excluded: their mtimes are always newer than any
  # earlier edition's ISO, which made this warn on every multi-edition run.
  # Their true sources (variants/) are in the list.
  newer=$(find build.sh config.env auto editions variants extras \
               config/hooks config/package-lists config/bootloaders \
               -type f \
               ! -name '25-gpu-nvidia.list.chroot' ! -name '30-dev.list.chroot' \
               ! -name '40-security.list.chroot' ! -name '50-gaming.list.chroot' \
               ! -name 'live.list.chroot' \
               -newer "$iso" -print -quit 2>/dev/null)
  [ -n "$newer" ] && w "ISO predates a build-source change ($newer) — rebuild before trusting FAILs"
  before=$FAIL
  structural "$iso"
  content "$iso" "$ed" "$var"
  [ "$FAIL" -ne "$before" ] && overall=1
done

echo; echo "==== summary: $PASS passed, $WARN warnings, $FAIL failed ===="
[ -n "$BOOT_ISO" ] && { echo; boot "$BOOT_ISO"; }
exit $overall
