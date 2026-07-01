#!/usr/bin/env bash
# Runtime validation: boot each ISO in QEMU, screenshot the live desktop, and
# run in-guest checks (conky/plasma running, theme applied, dotfiles in the live
# user's home, apps present). Complements validate-iso.sh (which checks the ISO
# on disk without booting).
#
#   ./validate-boot.sh                 # boot-validate all out/*.iso
#   ./validate-boot.sh out/x.iso ...   # specific ISOs
#
# Needs qemu-system-x86_64 and access to /dev/kvm (be in the 'kvm' group, or run
# with sudo). Requires ISOs built with qemu-guest-agent + live autologin (the
# current source). Artifacts (PNGs + <name>.report.txt) land in out/boot-validate/.
set -uo pipefail
cd "$(dirname "$0")" || exit 2

OUT="${OUT:-out/boot-validate}"; mkdir -p "$OUT"
LOG="$OUT/boot-validate.log"; exec > >(tee "$LOG") 2>&1

command -v qemu-system-x86_64 >/dev/null || { echo "need qemu: sudo apt install qemu-system-x86"; exit 1; }
command -v python3 >/dev/null           || { echo "need python3"; exit 1; }
[ -r /dev/kvm ] || echo "WARN: /dev/kvm not accessible — boots will be very slow (TCG). Add yourself to the 'kvm' group or use sudo."

isos=("$@"); [ "${#isos[@]}" -gt 0 ] || isos=(out/*.iso)
rc=0
for iso in "${isos[@]}"; do
  [ -f "$iso" ] || { echo "skip (not found): $iso"; continue; }
  python3 validate-boot.py "$iso" --out "$OUT" || rc=1
done
echo
echo "==== boot validation done. Screenshots + reports in: $OUT/ ===="
ls -1 "$OUT"/*.png "$OUT"/*.report.txt 2>/dev/null | sed 's/^/  /'
exit "$rc"
