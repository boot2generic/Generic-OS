#!/usr/bin/env bash
# Containerized ISO build. Builds a Debian-trixie image with the full
# live-build toolchain, runs ./build.sh inside a privileged, auto-removed
# container, and writes ISOs to iso/out/. Keeps the host free of the build
# toolchain — only a container runtime is needed on the host.
#
#   sudo ./container-build.sh                 # build all editions (config.env)
#   sudo ./container-build.sh security        # build one edition
#   sudo ./container-build.sh gaming nvidia   # build one edition/variant
#   sudo ./container-build.sh clean           # remove build artifacts (keeps image + cache)
#   sudo ./container-build.sh purge           # clean + remove container image and cache
#
#   sudo NO_UPDATE_DOTFILES=1 ./container-build.sh security   # skip the dotfiles pull
#
# Requirements are handled here: a runtime (podman, else docker, else podman
# is installed via apt) and everything else lives inside the image.
set -euo pipefail

ISO_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$ISO_DIR/.." && pwd)"
cd "$ISO_DIR"
IMAGE="generic-os-build"
INC="config/includes.chroot"

[[ $EUID -eq 0 ]] || { echo "run with sudo — the runtime + live-build need root: sudo ./container-build.sh $*"; exit 1; }

detect_runtime() { for c in podman docker; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }; done; echo ""; }
RT="$(detect_runtime)"

clean() {   # $1=purge → also drop the download cache and the runtime image
  local purge="${1:-}"
  if [ -n "$RT" ] && [ "$purge" = purge ]; then
    echo "[container] removing containers + image '$IMAGE'…"
    # shellcheck disable=SC2046
    "$RT" rm -f $("$RT" ps -aq --filter "ancestor=$IMAGE" 2>/dev/null) 2>/dev/null || true
    "$RT" rmi -f "$IMAGE" 2>/dev/null || true
  fi
  echo "[container] removing host build artifacts…"
  ./auto/clean 2>/dev/null || true
  rm -rf "${INC:?}/etc" "${INC:?}/usr" "${INC:?}/opt" config/includes.chroot_before_packages
  rm -rf .build chroot binary
  local l
  for l in 25-gpu-nvidia 30-dev 40-security 50-gaming live; do rm -f "config/package-lists/$l.list.chroot"; done
  if [ "$purge" = purge ]; then
    rm -rf cache
    echo "[container] purge complete (download cache + image removed)."
  else
    echo "[container] clean complete. Kept: cache/ (fast rebuilds) and out/*.iso + the build image."
    echo "[container] full wipe incl. cache + image: sudo ./container-build.sh purge"
  fi
}

case "${1:-}" in
  clean) clean; exit 0 ;;
  purge) clean purge; exit 0 ;;
esac

# Ensure a container runtime is available.
if [ -z "$RT" ]; then
  echo "[container] no podman/docker found — installing podman…"
  apt-get update && apt-get install -y --no-install-recommends podman
  RT="podman"
fi
echo "[container] runtime: $RT"

# Build the build-image from an inline Containerfile. An empty build context
# (mktemp dir) avoids tarring the whole iso/ tree (chroot/, out/, …) to the
# runtime — the image COPYs nothing; the project is bind-mounted at run time.
echo "[container] building image '$IMAGE' (Debian trixie + live-build toolchain)…"
CTX="$(mktemp -d)"
"$RT" build -t "$IMAGE" -f - "$CTX" <<'CONTAINERFILE'
FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      live-build debootstrap squashfs-tools xorriso \
      dosfstools mtools e2fsprogs file \
      rsync gpg curl ca-certificates git apt-utils \
 && rm -rf /var/lib/apt/lists/*
# The repo is bind-mounted (host-owned) — let container root operate on it.
RUN git config --global --add safe.directory '*'
WORKDIR /project/iso
CONTAINERFILE
rmdir "$CTX" 2>/dev/null || true

# Run the build inside the container.
#   --privileged: live-build needs mount, debootstrap chroot, and loop devices.
#   --rm: the container is torn down automatically when the build finishes.
echo "[container] running build (container is auto-removed on exit)…"
# Speed knobs are forwarded from the host env into the container so
# `sudo FAST=1 APT_PROXY=… ./container-build.sh …` reaches build.sh/auto/config.
# (VAR after sudo: default env_reset strips VARs set before sudo.)
# An APT_PROXY on localhost lives on the host, so use the host network namespace
# to make localhost:3142 inside the container hit the host's apt-cacher-ng.
NET_ARGS=()
[[ "${APT_PROXY:-}" == *localhost* || "${APT_PROXY:-}" == *127.0.0.1* ]] && NET_ARGS=(--network host)
"$RT" run --rm --privileged "${NET_ARGS[@]}" \
  -e "NO_UPDATE_DOTFILES=${NO_UPDATE_DOTFILES:-0}" \
  -e "FAST=${FAST:-0}" \
  -e "SQUASHFS_LEVEL=${SQUASHFS_LEVEL:-}" \
  -e "SQUASHFS_COMP=${SQUASHFS_COMP:-}" \
  -e "APT_PROXY=${APT_PROXY:-}" \
  -v "$PROJECT_DIR":/project \
  -w /project/iso \
  "$IMAGE" ./build.sh "$@"

# ISOs were written to the bind-mounted out/ as container-root → hand back.
[[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" out 2>/dev/null || true
echo "[container] done. ISOs in iso/out/."
echo "[container] image '$IMAGE' kept for fast rebuilds; 'sudo ./container-build.sh purge' removes it (clean keeps it)."
