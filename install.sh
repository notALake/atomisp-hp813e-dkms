#!/usr/bin/env bash
# Build patched atomisp + mt9m114 as DKMS modules for the target linux-zen
# kernel, without rebuilding the kernel.
#
# Sources come from the zen-kernel tag matching the kernel being built and are
# patched with the set in ./patches. Only atomisp/, mt9m114.c and aptina-pll.h
# are downloaded; they are cached per tag in ~/.cache/atomisp-hp813e/<tag>
# (override with ATOMISP_CACHE, re-download with --refresh).
#
# The DKMS version is the patch set number (PATCHSET), not the kernel version,
# so the same DKMS entry is reused for every kernel.
#
# Usage: sudo ./install.sh [--kver 7.2.11-zen1-1-zen] [--prepare-only]
#                          [--no-firmware] [--tarball|--kernelorg] [--refresh]
#                          [--hook]
#
# --hook is the mode used by the pacman hook: it scans every installed kernel
# that has headers and rebuilds the ones without atomisp modules, invoking this
# script with --kver once per kernel.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="$(uname -r)"
PREPARE_ONLY=0
USE_TARBALL=0
USE_KORG=0
FIRMWARE=1
REFRESH=0
HOOK=0
PATCHSET=16
while [ $# -gt 0 ]; do
  case "$1" in
    --kver) KVER="$2"; shift 2 ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --no-firmware) FIRMWARE=0; shift ;;
    --tarball) USE_TARBALL=1; shift ;;
    --kernelorg) USE_KORG=1; shift ;;
    --refresh) REFRESH=1; shift ;;
    --hook) HOOK=1; shift ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

# The pacman hook runs as root without SUDO_USER and without knowing where the
# repository is, so it uses a fixed copy of this script.
KIT="/usr/local/share/atomisp-hp813e"
HOOK_FILE="/etc/pacman.d/hooks/75-atomisp-hp813e.hook"
LOGDIR="/var/log/atomisp-hp813e"

# --- --hook mode: invoked at the end of a pacman transaction. Each run handles
#     one kernel, so the per-kernel DKMS cleanup of one run cannot interfere
#     with the next one. A build failure makes the hook exit non-zero.
if [ "$HOOK" = 1 ]; then
  [ "$(id -u)" = 0 ] || { echo "atomisp-hp813e --hook: root required"; exit 1; }
  rc=0; n=0
  # dkms status is slow: capture it once. Do not pipe it into `grep -q`: grep
  # exits at the first match, dkms gets SIGPIPE and, with pipefail, the pipeline
  # reports failure even when the module is installed.
  DKMS_STATUS="$(dkms status 2>/dev/null || true)"
  for k in $(ls -1 /usr/lib/modules 2>/dev/null | sort -V); do
    [ -e "/usr/lib/modules/$k/build" ] || continue        # no headers: cannot build
    if grep -qE "^atomisp-hp813e/[^, ]*, $k, [^:]*: installed" <<<"$DKMS_STATUS"; then
      continue                                            # already installed
    fi
    echo "==> hook: kernel $k has no atomisp modules -> rebuilding from zen-kernel"
    n=$((n + 1))
    bash "$0" --kver "$k" || rc=1
  done
  if [ "$n" = 0 ]; then
    echo "==> hook: all installed kernels already have the atomisp-hp813e modules"
  elif [ "$rc" != 0 ]; then
    echo "!! hook: some builds failed, run them again by hand:"
    echo "   sudo $KIT/install.sh"
    echo "   (failed build logs: $LOGDIR)"
  fi
  exit $rc
fi

# --- 7.2.11-zen1-1-zen  ->  base=7.2.11  zen=zen1  (also "7.2.zen1-1-zen" for x.y.0)
if [[ "$KVER" =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?)[.-](zen[0-9]+) ]]; then
  BASE="${BASH_REMATCH[1]}"; ZEN="${BASH_REMATCH[3]}"
else
  echo "ERROR: '$KVER' does not look like a linux-zen kernel (expected e.g. 7.2.11-zen1-1-zen)"; exit 1
fi
TAG="v${BASE}-${ZEN}"
PKG="atomisp-hp813e"
VER="${PATCHSET}"
DEST="/usr/src/${PKG}-${VER}"
[ "$PREPARE_ONLY" = 1 ] && DEST="${PWD}/${PKG}-${VER}"

echo "==> kernel $KVER  ->  zen-kernel tag $TAG  ->  $DEST"

if [ "$PREPARE_ONLY" = 0 ]; then
  [ "$(id -u)" = 0 ] || { echo "root required (sudo)"; exit 1; }
  for c in dkms git patch make gcc; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 1; }; done
  [ -d "/lib/modules/$KVER/build" ] || { echo "missing headers: pacman -S linux-zen-headers"; exit 1; }

  # --- atomisp cannot create these dependencies itself: check the kernel config
  CFG="/lib/modules/$KVER/build/.config"
  miss=0
  for s in VIDEO_DEV MEDIA_PCI_SUPPORT INTEL_SKL_INT3472 IPU_BRIDGE PMIC_OPREGION I2C \
           V4L2_FWNODE IOSF_MBI VIDEOBUF2_VMALLOC VIDEO_V4L2_SUBDEV_API VIDEO_MT9M114 VIDEO_APTINA_PLL V4L2_CCI_I2C; do
    if ! grep -Eq "^CONFIG_${s}=(y|m)" "$CFG"; then echo "   MISSING in the kernel: CONFIG_$s"; miss=1; fi
  done
  [ "$miss" = 0 ] || { echo "ERROR: missing dependencies; an external module cannot provide them (a rebuilt kernel is required)"; exit 1; }

  # --- stable kit used by the pacman hook. Running from the repository always
  #     refreshes it; running from the kit itself skips the copy.
  if [ "$(readlink -f "$HERE")" != "$(readlink -f "$KIT")" ]; then
    mkdir -p "$KIT"
    rm -rf "$KIT/patches"
    cp -f "$HERE/install.sh" "$KIT/install.sh"
    chmod 755 "$KIT/install.sh"
    cp -r "$HERE/patches" "$KIT/patches"
    if [ -f "$HERE/shisp_2401a0_v21.bin" ] && [ ! -f "$KIT/shisp_2401a0_v21.bin" ]; then
      cp -f "$HERE/shisp_2401a0_v21.bin" "$KIT/"
    fi
    echo "==> kit installed in $KIT (this is the copy used by the pacman hook)"
  fi

  # --- pacman hook: on every install/upgrade of a kernel (or its headers) it
  #     runs this script in --hook mode, so after `pacman -Syu` you only need to
  #     reboot. Exec is derived from $KIT so the hook does not depend on the
  #     repository location.
  mkdir -p "$(dirname "$HOOK_FILE")"
  cat > "$HOOK_FILE" <<HOOK
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/modules.order
Target = usr/lib/modules/*/build/include/

[Action]
Description = Build atomisp-hp813e DKMS modules for new kernels
When = PostTransaction
Depends = dkms
Exec = $KIT/install.sh --hook
HOOK
  echo "==> pacman hook written: $HOOK_FILE"
fi

# --- sources: only atomisp + mt9m114.c from the zen-kernel tag matching the kernel
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "$DEST.tmp"' EXIT
export GIT_TERMINAL_PROMPT=0
REPO=https://github.com/zen-kernel/zen-kernel
KSRC="$TMP/git"
WANT_DIR=drivers/staging/media/atomisp
WANT_FILE=drivers/media/i2c/mt9m114.c
WANT_HDR=drivers/media/i2c/aptina-pll.h   # local header included by mt9m114.c (the code is in the kernel's aptina-pll.ko)

# --- source cache: key = kernel tag ($TAG). With sudo, use the cache of the
#     user who invoked it, so it is shared with non-sudo runs and does not end
#     up in /root.
if [ -n "${ATOMISP_CACHE:-}" ]; then
  CACHE="$ATOMISP_CACHE"
else
  _home="$HOME"
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    _ushome="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    [ -n "${_ushome:-}" ] && _home="$_ushome"
  fi
  CACHE="${_home:-$HOME}/.cache/atomisp-hp813e"
fi
CSRC="$CACHE/$TAG"

cache_ok() {
  [ -f "$CSRC/$WANT_FILE" ] && [ -f "$CSRC/$WANT_HDR" ] && [ -d "$CSRC/$WANT_DIR" ]
}

fetch_git() {
  # HTTP/1.1 + timeout: on some networks HTTP/2 or IPv6 make git hang without output
  timeout 90 git -c http.version=HTTP/1.1 clone --progress --filter=blob:none --no-checkout \
      --depth 1 --branch "$TAG" "$REPO" "$KSRC" &&
  git -C "$KSRC" sparse-checkout set --no-cone "/$WANT_DIR/" "/$WANT_FILE" "/$WANT_HDR" &&
  timeout 120 git -c http.version=HTTP/1.1 -C "$KSRC" checkout
}
fetch_tarball() {
  # tag tarball on GitHub (~250 MB); extract only the paths we need
  rm -rf "$KSRC"; mkdir -p "$KSRC"
  curl -fL --retry 1 --connect-timeout 15 --progress-bar "$REPO/archive/refs/tags/${TAG}.tar.gz" \
    | tar -xz -C "$KSRC" --strip-components=1 --wildcards "*/$WANT_DIR" "*/$WANT_FILE" "*/$WANT_HDR"
}
fetch_kernelorg() {
  # kernel.org (not GitHub): for atomisp and mt9m114.c the stable x.y.z kernel is
  # identical to the zen tag (verified with git hashes for 7.2.9). Tarball ~150 MB
  # .tar.xz; extract only the paths we need.
  local major="${BASE%%.*}" ver="$BASE"
  local url="${KERNELORG_URL:-https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${ver}.tar.xz}"
  rm -rf "$KSRC"; mkdir -p "$KSRC"
  curl -fL --retry 2 --connect-timeout 15 --progress-bar "$url" \
    | tar -xJ -C "$KSRC" --strip-components=1 --wildcards "*/$WANT_DIR" "*/$WANT_FILE" "*/$WANT_HDR"
}

if [ "$REFRESH" = 0 ] && cache_ok; then
  echo "==> using cached sources: $CSRC"
  echo "    (--refresh to re-download them, ATOMISP_CACHE to change the cache)"
  SRC="$CSRC"
else
  if [ "$USE_KORG" = 1 ]; then
    echo "==> downloading $BASE sources from kernel.org (atomisp + mt9m114 only)..."
    fetch_kernelorg
  elif [ "$USE_TARBALL" = 1 ]; then
    echo "==> downloading the $TAG tarball from GitHub (atomisp + mt9m114 only)..."
    fetch_tarball
  else
    echo "==> downloading zen-kernel sources ($TAG) via git (90s timeout)..."
    if ! fetch_git; then
      echo "==> git did not respond (GitHub rate limit?): trying the GitHub tarball..."
      if ! fetch_tarball; then
        echo "==> GitHub unavailable: falling back to kernel.org..."
        fetch_kernelorg
      fi
    fi
  fi
  [ -f "$KSRC/$WANT_FILE" ] && [ -d "$KSRC/$WANT_DIR" ] || { echo "ERROR: sources were not downloaded correctly"; exit 1; }

  # --- cache only the paths we need, so the next build can reuse them
  if rm -rf "$CSRC" &&
     mkdir -p "$CSRC/$(dirname "$WANT_FILE")" "$CSRC/drivers/staging/media" &&
     cp "$KSRC/$WANT_FILE" "$KSRC/$WANT_HDR" "$CSRC/$(dirname "$WANT_FILE")/" &&
     cp -r "$KSRC/$WANT_DIR" "$CSRC/drivers/staging/media/"; then
    echo "==> sources cached in $CSRC"
    SRC="$CSRC"
  else
    echo "==> warning: cache is not writable ($CSRC), using the temporary sources"
    SRC="$KSRC"
  fi
fi

# --- working tree with the same paths as the kernel, so patches apply as-is
W="$TMP/w"; mkdir -p "$W/drivers/media/i2c" "$W/drivers/staging/media"
cp "$SRC/$WANT_FILE" "$SRC/$WANT_HDR" "$W/drivers/media/i2c/"
cp -r "$SRC/$WANT_DIR" "$W/drivers/staging/media/"

echo "==> applying patches"
for p in "$HERE"/patches/0*.patch; do
  printf '   %s ... ' "$(basename "$p")"
  (cd "$W" && patch -Np1 --no-backup-if-mismatch -s < "$p") && echo ok \
    || { echo "FAILED"; echo "The patches do not apply to $TAG: the driver changed and they need to be updated."; exit 1; }
done

# --- DKMS layout. Build in "$DEST.tmp" and move it to $DEST only when complete:
#     if a copy/sed fails, the previous DKMS entry remains valid with its
#     sources instead of being left half-written.
DST="$DEST.tmp"
rm -rf "$DST"; mkdir -p "$DST"
cp -r "$W/drivers/staging/media/atomisp" "$DST/atomisp"
cp "$W/drivers/media/i2c/mt9m114.c" "$W/drivers/media/i2c/aptina-pll.h" "$DST/"
rm -rf "$DST/atomisp/i2c"         # OV2722/GC2235 sensors: not needed for the MT9M114

# atomisp Makefile: no Kconfig outside the tree -> force obj-m and relative paths
sed -i -e '/^obj-\$(CONFIG_INTEL_ATOMISP) += i2c\/$/d' \
       -e 's/^obj-\$(CONFIG_VIDEO_ATOMISP)/obj-m/' \
       -e 's#\$(srctree)/drivers/staging/media/atomisp/#$(src)/#' \
       "$DST/atomisp/Makefile"

cat > "$DST/Kbuild" <<KB
# out-of-tree modules: atomisp.ko + atomisp_gmin_platform.ko + mt9m114.ko (patched)
obj-m += atomisp/
obj-m += mt9m114.o
KB

cat > "$DST/dkms.conf" <<DK
PACKAGE_NAME="$PKG"
PACKAGE_VERSION="$VER"
AUTOINSTALL="yes"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
BUILT_MODULE_NAME[0]="atomisp"
BUILT_MODULE_LOCATION[0]="atomisp/"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="atomisp_gmin_platform"
BUILT_MODULE_LOCATION[1]="atomisp/pci/"
DEST_MODULE_LOCATION[1]="/updates/dkms"
BUILT_MODULE_NAME[2]="mt9m114"
BUILT_MODULE_LOCATION[2]=""
DEST_MODULE_LOCATION[2]="/updates/dkms"
DK

rm -rf "$DEST"; mv "$DST" "$DEST"

if [ "$PREPARE_ONLY" = 1 ]; then
  echo "==> DKMS sources ready in $DEST (--prepare-only: nothing installed)"; exit 0
fi

# ---------------------------------------------------------------------------
# Existing DKMS versions.
#
# A healthy entry (name $PKG, sources present, at least one installed kernel)
# is never removed: it is the fallback for the other kernels and for
# `dkms autoinstall`.
#
# Phase 1, before `dkms add`: remove only the entries that are useless or would
#   block the add (wrong name, missing sources, no kernels, the version being
#   rebuilt on the target kernel).
# Phase 2, after a successful build, before `dkms install`: remove a different
#   version from the target kernel only. Two versions cannot share
#   /lib/modules/$KVER/updates/dkms, otherwise removing the old one deletes the
#   modules just installed.
#
# Sources are never deleted here; the orphan sweep below takes care of them.
# ---------------------------------------------------------------------------
src_missing() { [ ! -f "/usr/src/$1/dkms.conf" ]; }
ks_of() {   # kernels associated with "pkg/ver" (one dkms status line per kernel)
  dkms status 2>/dev/null | grep -F "$1, " | awk -F', ' '{print $2}' | sort -u || true
}
list_entries() {
  dkms status 2>/dev/null | sed -E 's/[:,].*//' | grep '^atomisp-hp813e' | sort -u || true
}

# make.log lives inside the tree that `dkms remove` deletes: back it up first.
save_logs() {   # $1=pkg $2=ver
  local m="$1" v="$2" lg i=0 ts
  ts="$(date +%Y%m%d-%H%M%S)"
  for lg in "/var/lib/dkms/$m/$v/build/make.log" /var/lib/dkms/"$m"/"$v"/*/*/log/make.log; do
    [ -f "$lg" ] || continue
    mkdir -p "$LOGDIR"
    i=$((i + 1))
    cp "$lg" "$LOGDIR/${m}_${v}_${ts}_${i}.make.log"
    echo "    log saved: $LOGDIR/${m}_${v}_${ts}_${i}.make.log"
  done
}

drop_entry() {   # $1="pkg/ver"  $2=kernel (empty = whole entry)
  local full="$1" k="${2:-}" m v
  m=${full%%/*}; v=${full#*/}
  save_logs "$m" "$v"
  if [ -n "$k" ]; then
    dkms remove "$full" -k "$k" || true
  else
    dkms remove "$full" --all || rm -rf "/var/lib/dkms/$m/$v"
  fi
}

prune() {   # $1 = 1 | 2
  local phase="$1" full m v ks k why kern nalive
  for full in $(list_entries); do
    m=${full%%/*}; v=${full#*/}
    ks="$(ks_of "$full")"
    why=""; kern=""
    if [ "$phase" = 1 ]; then
      if [ "$m" != "$PKG" ]; then
        why="ghost entry (name '$m', created by Arch's hook from a dashed directory)"
      elif [ "$v" = "$VER" ]; then
        why="this is the version being rebuilt (removed from $KVER only)"; kern="$KVER"
      elif src_missing "$m-$v"; then
        why="broken entry: sources are missing"
      elif [ -z "$ks" ]; then
        why="entry with no associated kernels"
      else
        nalive=0
        for k in $ks; do
          [ -d "/usr/lib/modules/$k" ] && nalive=$((nalive + 1))
        done
        [ "$nalive" = 0 ] && why="none of its kernels is installed"
      fi
    else
      [ "$m" = "$PKG" ] && [ "$v" != "$VER" ] || continue
      grep -qx "$KVER" <<<"$ks" || continue
      why="old version on the target kernel (removed from $KVER only)"; kern="$KVER"
    fi
    if [ -z "$why" ]; then
      echo "==> keeping $full (healthy: fallback for other kernels and dkms autoinstall)"
      continue
    fi
    echo "==> removing DKMS entry $full ($why)"
    drop_entry "$full" "$kern"
  done
}

# Orphaned sources: they belong to no live DKMS entry and are not $DEST.
# First verify that dkms really responds: on a lock or transient error status
# is empty, and the sweep would delete the sources of entries that exist.
sweep() {
  local alive full d
  if dkms status >/dev/null 2>&1; then
    alive=" "
    for full in $(list_entries); do
      alive="$alive${full%%/*}-${full#*/} "
    done
    alive="$alive${DEST##*/} ${DEST##*/}.tmp "
    for d in /usr/src/atomisp-hp813e*; do
      [ -e "$d" ] || continue
      case "$alive" in *" ${d##*/} "*) continue ;; esac
      echo "==> removing orphaned sources $d"; rm -rf "$d"
    done
  else
    echo "==> warning: dkms status is not responding, skipping orphaned source cleanup"
  fi
}

prune 1
sweep

dkms add "$PKG/$VER" 2>&1 || true
if ! dkms build -m "$PKG" -v "$VER" -k "$KVER"; then
  save_logs "$PKG" "$VER"
  echo "!! build of $PKG/$VER for $KVER FAILED."
  echo "   Logs: $LOGDIR (and /var/lib/dkms/$PKG/$VER/build/make.log)."
  echo "   The other healthy versions were left untouched."
  exit 1
fi

prune 2
sweep
dkms install -m "$PKG" -v "$VER" -k "$KVER" --force

# intel_atomisp2_pm claims the same PCI device as the ISP
cat > /etc/modprobe.d/atomisp-hp813e.conf <<'MP'
# atomisp and intel_atomisp2_pm are alternatives on the same PCI device (ISP, 00:03.0)
blacklist intel_atomisp2_pm
install intel_atomisp2_pm /bin/false
MP

if [ "$FIRMWARE" = 1 ]; then
  # The firmware is provided by linux-firmware-intel in
  # /usr/lib/firmware/intel/ipu/ (compressed as .zst) and the driver looks
  # there first: no need to copy it. Use the copy next to this script only when
  # the system does not have it.
  FW_NEW=/usr/lib/firmware/intel/ipu/shisp_2401a0_v21.bin
  FW_NEW_ZST=$FW_NEW.zst
  FW_LEGACY=/lib/firmware/shisp_2401a0_v21.bin
  if [ -f "$HERE/shisp_2401a0_v21.bin" ]; then
    install -Dm644 "$HERE/shisp_2401a0_v21.bin" "$FW_LEGACY"
    echo "==> firmware installed from this directory to $FW_LEGACY"
  elif [ -f "$FW_NEW" ]; then
    echo "==> firmware already present ($FW_NEW)"
  elif [ -f "$FW_NEW_ZST" ]; then
    echo "==> firmware already present ($FW_NEW_ZST, the kernel decompresses it itself)"
    # also copy to the unprefixed path, for kernels that only look there
    if [ ! -e "$FW_LEGACY" ] && command -v zstd >/dev/null; then
      zstd -dc "$FW_NEW_ZST" > "$FW_LEGACY" && echo "    (also copied to $FW_LEGACY)"
    fi
  else
    echo "!! WARNING: firmware shisp_2401a0_v21.bin not found."
    echo "   Install the linux-firmware-intel package."
  fi
fi
depmod "$KVER"

# modprobe always acts on the running kernel: with --kver (or from the pacman
# hook, which runs before the reboot) the target kernel is not the current one,
# so there is nothing to reload; the modules will be used on the next boot.
if [ "$KVER" != "$(uname -r)" ]; then
  echo "==> $KVER: modules built and installed (this is not the running kernel:"
  echo "    they will be active after the next reboot)"
else
  # Reload both modules now, so no reboot is needed. mt9m114 is the sensor
  # driver and is often already loaded from the stock kernel (without the flip
  # and the AE fix): if it stays loaded, the image is upside down and
  # overexposed. If the webcam is open, rmmod fails: close the program and
  # reload manually.
  fail=0
  if grep -q '^atomisp ' <<<"$(lsmod)"; then
    modprobe -r atomisp 2>/dev/null || fail=1
  fi
  if [ "$fail" = 0 ] && grep -q '^mt9m114 ' <<<"$(lsmod)"; then
    modprobe -r mt9m114 2>/dev/null || true
  fi
  if [ "$fail" = 0 ] && modprobe atomisp 2>/dev/null; then
    echo "==> modules reloaded (atomisp) - no reboot needed"
  else
    echo "==> could not reload the modules: close the webcam and run"
    echo "    sudo modprobe -r atomisp mt9m114 && sudo modprobe atomisp   (or reboot)"
  fi
  # verify that mt9m114 is the patched one (updates/dkms), not the stock kernel's
  case "$(modinfo -n mt9m114 2>/dev/null || true)" in
    */updates/dkms/*) echo "    mt9m114: patched version ($(modinfo -n mt9m114))" ;;
    "")               echo "    mt9m114: not loaded, it will be loaded at boot" ;;
    *)  echo "    WARNING: the mt9m114 in use is the stock kernel one (no flip, no AE fix)"
        echo "      sudo modprobe -r mt9m114 && sudo modprobe mt9m114" ;;
  esac
fi
echo "==> done."
echo "    Check: modinfo atomisp | head -3 ; dmesg | grep -i -E 'atomisp|mt9m114'"
