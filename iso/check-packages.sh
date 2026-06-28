#!/usr/bin/env bash
# Verify every package referenced in the Debian package lists actually has an
# install candidate in the configured apt suite (catches packages that exist
# in metadata but can't be installed — e.g. removed-from-testing). Run on a
# host matching DEBIAN_SUITE with the same archive-areas. No root needed.
#
# NOTE: `apt-cache show` is NOT sufficient — it succeeds for packages with no
# installation candidate. We check the Candidate line, like apt-get install.
#
# Kali tools (extras/kali/kali-tools.list) are not checked: they resolve only
# against the Kali repo, which isn't on the build/validation host.
set -euo pipefail
cd "$(dirname "$0")"

mapfile -t lists < <(ls config/package-lists/*.list.chroot \
                        variants/stacks/*.list.chroot \
                        variants/nvidia/*.list.chroot 2>/dev/null)
pkgs=$(cat "${lists[@]}" 2>/dev/null | grep -vE '^\s*#' | sed 's/#.*//' \
        | tr -d ' \t' | grep -vE '^$' | sort -u)

bad=()
for p in $pkgs; do
  cand=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')
  if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then bad+=("$p"); fi
done

n=$(printf '%s\n' "$pkgs" | grep -c .)
if [ ${#bad[@]} -eq 0 ]; then
  echo "OK: all $n Debian packages have an install candidate."
else
  echo "FAIL: ${#bad[@]}/$n package(s) have NO install candidate:"
  printf '  - %s\n' "${bad[@]}"
  exit 1
fi
