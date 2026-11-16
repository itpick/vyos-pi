#!/usr/bin/env bash
# Run a command in the vyos-build container (arm64), building the container
# first from vyos-build's own Dockerfile at VYOS_BUILD_REV.
#
#   scripts/container.sh scripts/build-iso.sh [VERSION]
#
# Needs docker on an arm64 host (Linux, or Docker Desktop / OrbStack on an
# Apple Silicon Mac). The checkout is mounted at /vyos-pi; the named volume
# vyos-pi-work (WORK=/work: vyos-build checkout, kernel package cache) is kept
# between runs.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
source versions.env
image=vyos-pi-build:${VYOS_BUILD_REV:0:12}
if ! docker image inspect "$image" >/dev/null 2>&1; then
  ctx=$(mktemp -d)
  trap 'rm -rf "$ctx"' EXIT
  git clone -q "$VYOS_BUILD_REPO" "$ctx/vyos-build"
  git -C "$ctx/vyos-build" checkout -q "$VYOS_BUILD_REV"
  docker build --platform linux/arm64 -t "$image" "$ctx/vyos-build/docker"
fi
tty=(); [ -t 0 ] && tty=(-t)
exec docker run --rm -i "${tty[@]}" --privileged --platform linux/arm64 \
  --sysctl net.ipv6.conf.lo.disable_ipv6=0 \
  -v "$PWD:/vyos-pi" -v "${VYOS_PI_WORK:-vyos-pi-work}:/work" -v /dev:/dev \
  -e WORK=/work -e COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -w /vyos-pi --entrypoint /bin/bash "$image" "$@"
