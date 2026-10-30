#!/usr/bin/env bash
# Colibry ISO builder with store hygiene and build verification.
#
# A full ISO build writes 15-30 GB of new paths into the Nix store, so this
# wrapper garbage-collects every store path the fresh image does not
# reference once the build succeeds. The result link is created by nix
# itself at the end of a successful build, therefore a failed build never
# touches the last working ISO.
#
# Usage:
#   ./build.sh          build the ISO, print its hash, clean the store
#   ./build.sh clean    remove the ISO link and every unreachable store
#                       path (old profile generations included), then
#                       deduplicate identical files
#   ./build.sh run      build, clean, then boot the ISO in QEMU via run.sh
set -euo pipefail
cd "$(dirname "$0")"

# Name of the symlink that points at the built image derivation. nix
# creates this link itself at the end of a successful build and registers
# it as a garbage collector root, which keeps the image alive through the
# store cleanup below.
ISO_LINK=result

# The new build materializes its full closure while the old one is still
# on disk, so the build refuses to start below this free-space threshold
# instead of dying with a full disk halfway through.
MIN_FREE_GB=40

# How many times a failed nix build is retried before giving up. Every
# already downloaded or built path stays in the store, so a retry always
# continues where the previous attempt stopped; only genuine evaluation
# errors repeat identically and surface after the last attempt.
BUILD_ATTEMPTS=3

# Preflight: every wizard and installer script must parse before any nix
# work starts. A script corrupted in transfer would otherwise surface its
# syntax error only inside the virtual machine, half an hour after the
# build began; here the same failure takes milliseconds and names the file.
for script in \
    scripts/colibry-oobe.sh \
    scripts/colibry-oobe-term.sh \
    scripts/colibry-oobe-widgets.sh \
    scripts/install-to-disk.sh \
    scripts/install-system.sh; do
  if [ -f "$script" ] && ! bash -n "$script" 2>/dev/null; then
    echo "error: $script does not parse; the file is corrupted - replace it with a fresh copy." >&2
    bash -n "$script" 2>&1 | head -n 3 >&2
    exit 1
  fi
done

# Free gigabytes on the file system that holds /nix (portable: plain df
# in 1K blocks, no GNU-only flags).
free_gb() {
  df -k /nix | awk 'NR == 2 { printf "%d", $4 / 1048576 }'
}

# gc_quiet COMMAND...: run a store cleanup command and reduce its output
# to a single summary line. Cleanup commands log one line per deleted
# path - hundreds of lines on a full build - and write those lines to
# stderr, so a full transcript is redirected into a temporary log: on
# success only the freed space is printed, on failure the complete log
# is shown to diagnose the failing cleanup.
gc_quiet() {
  local before after log
  before=$(free_gb)
  log=$(mktemp)
  if "$@" >"$log" 2>&1; then
    after=$(free_gb)
    rm -f "$log"
    echo "cleanup done: $((after - before)) GiB freed, $after GiB free on /nix"
  else
    cat "$log" >&2
    rm -f "$log"
    echo "error: cleanup command failed: $*" >&2
    exit 1
  fi
}

# clean: drop the public ISO link, prune every unreachable store path
# (including old profile generations, which a plain store GC keeps alive),
# then hardlink identical files inside the remaining store.
clean() {
  rm -f "$ISO_LINK"
  gc_quiet nix-collect-garbage -d
  gc_quiet nix-store --optimise
}

# Print the ISO file contained in an image derivation, or nothing if the
# derivation does not contain exactly one ISO file.
iso_of() {
  find "$1/iso" -maxdepth 1 -type f -name '*.iso' -print -quit
}

# build_iso: build the image, verify the ISO exists, report size and
# SHA-256 of the image, then garbage collect every path the previous
# build kept alive.
build_iso() {
  local avail iso iso_real attempt
  avail=$(free_gb)
  if [ "$avail" -lt "$MIN_FREE_GB" ]; then
    echo "error: only ${avail} GiB free on /nix; at least ${MIN_FREE_GB} GiB are needed for a build." >&2
    echo "free some space (for example: ./build.sh clean) and retry." >&2
    exit 1
  fi

  # nix writes the out-link only after the build succeeds: a failed build
  # leaves the previous result link untouched and the previous image
  # stays bootable. The link created here is registered by nix as a
  # garbage collector root under its final name, so the cleanup below
  # never collects the fresh image.
  for (( attempt = 1; attempt <= BUILD_ATTEMPTS; attempt++ )); do
    if nix build .#colibry-iso --out-link "$ISO_LINK" --print-build-logs; then
      break
    fi
    if [ "$attempt" -eq "$BUILD_ATTEMPTS" ]; then
      echo "error: the build failed ${BUILD_ATTEMPTS} times in a row; see the log above." >&2
      exit 1
    fi
    echo "build attempt ${attempt} failed; retrying (already fetched paths are kept)..." >&2
    sleep 5
  done

  iso=$(iso_of "$ISO_LINK")
  if [ -z "$iso" ]; then
    echo "error: build finished without producing an ISO file" >&2
    exit 1
  fi
  iso_real=$(readlink -f "$iso")

  echo "ISO ready: $iso_real"
  ls -lh "$iso_real"
  # The hash proves which exact image every later boot log belongs to and
  # catches stale artifacts copied around by hand.
  sha256sum "$iso_real"

  # Everything not reachable from the fresh result is garbage now:
  # previous ISO builds, failed-build debris, superseded dependencies.
  gc_quiet nix-store --gc
}

# Require the flake entry point so the error names the real problem
# instead of a deep nix evaluation failure.
[ -f flake.nix ] || { echo "error: flake.nix not found - run this script from the Colibry repository root." >&2; exit 1; }
command -v nix >/dev/null || { echo "error: nix is not installed or not on PATH." >&2; exit 1; }
# Pin the flake workflow for every nix invocation below.
export NIX_CONFIG="experimental-features = nix-command flakes"

case "${1:-build}" in
  clean)
    clean
    exit 0
    ;;
  build|'')
    build_iso
    ;;
  run)
    build_iso
    # Resolve the freshly published ISO into a checked variable first: a
    # resolution failure is reported here by name instead of surfacing as
    # a confusing argument error inside run.sh, and an empty value can
    # never reach the exec line below.
    iso_run=$(iso_of "$ISO_LINK")
    if [ -z "$iso_run" ]; then
      echo "error: build finished, but no ISO file exists under $ISO_LINK/iso/" >&2
      exit 1
    fi
    exec ./run.sh --iso "$(readlink -f "$iso_run")"
    ;;
  *)
    echo "usage: ./build.sh [build|clean|run]" >&2
    exit 2
    ;;
esac
