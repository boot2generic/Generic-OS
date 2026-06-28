#!/usr/bin/env bash
# Download the Kali archive keyring (online, build host) and hard-fail unless
# the pinned fingerprint is present — same trust discipline as the repo's
# Mullvad/LibreWolf installers. Writes the verified keyring to cache/.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
. ./config.env

OUT=cache/kali-archive-keyring.gpg
mkdir -p cache

echo "[kali-key] downloading $KALI_KEYRING_URL"
curl -fsSL --proto '=https' --tlsv1.2 "$KALI_KEYRING_URL" -o "$OUT"

echo "[kali-key] verifying fingerprint $KALI_KEY_FPR"
if ! gpg --show-keys --with-colons "$OUT" 2>/dev/null \
     | awk -F: '/^fpr:/{print $10}' | grep -qx "$KALI_KEY_FPR"; then
  echo "[kali-key] FATAL: pinned fingerprint not found in downloaded keyring" >&2
  echo "[kali-key] update KALI_KEY_FPR in config.env per" >&2
  echo "           https://www.kali.org/blog/new-kali-archive-signing-key/" >&2
  rm -f "$OUT"
  exit 1
fi
echo "[kali-key] OK → $OUT"
