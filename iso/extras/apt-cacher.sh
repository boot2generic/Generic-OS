#!/usr/bin/env bash
# Stand up apt-cacher-ng on the host so ISO builds reuse downloaded .debs across
# editions, rebuilds, and even `purge`. This turns cold builds warm and lets an
# all-editions run fetch the shared base (Plasma + dev) only once.
#
#   sudo ./extras/apt-cacher.sh            # install + start, print APT_PROXY
#   sudo ./extras/apt-cacher.sh status     # show cache size + service state
#   sudo ./extras/apt-cacher.sh stop       # stop the service (cache is kept)
#
# Then build through it (APT_PROXY *after* sudo — sudo's default env_reset
# strips variables set before it, silently disabling the proxy):
#   sudo APT_PROXY=http://localhost:3142 ./build.sh security
#   sudo APT_PROXY=http://localhost:3142 ./container-build.sh security
# (container-build.sh auto-adds --network host so localhost reaches the host.)
#
# apt still GPG-verifies every package, so caching over plain http is safe —
# auto/config drops the mirror to http only so apt-cacher-ng can see (and cache)
# the traffic; a TLS mirror would be an opaque tunnel it can't cache.
set -euo pipefail

PORT=3142
CACHE_DIR=/var/cache/apt-cacher-ng

[[ $EUID -eq 0 ]] || { echo "run with sudo: sudo ./extras/apt-cacher.sh $*"; exit 1; }

status() {
  systemctl is-active --quiet apt-cacher-ng && echo "service: running" || echo "service: stopped"
  [ -d "$CACHE_DIR" ] && echo "cache:   $(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1) at $CACHE_DIR" || echo "cache:   (none yet)"
  echo "proxy:   http://localhost:$PORT"
}

case "${1:-up}" in
  status) status; exit 0 ;;
  stop)   systemctl stop apt-cacher-ng; echo "stopped (cache kept at $CACHE_DIR)"; exit 0 ;;
  up|"")  ;;
  *)      echo "usage: apt-cacher.sh [up|status|stop]"; exit 1 ;;
esac

if ! command -v apt-cacher-ng >/dev/null 2>&1; then
  echo "[apt-cacher] installing apt-cacher-ng…"
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apt-cacher-ng
fi

systemctl enable --now apt-cacher-ng
echo
echo "[apt-cacher] ready. Build through it with:"
echo "    sudo APT_PROXY=http://localhost:$PORT ./container-build.sh <edition>"
echo "    sudo APT_PROXY=http://localhost:$PORT ./build.sh <edition>"
echo
status
