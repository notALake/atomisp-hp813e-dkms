#!/usr/bin/env bash
# Build patched atomisp + mt9m114 as DKMS modules for the running zen kernel,
# without rebuilding the kernel. Sources come from zen-kernel (same tag as the
# running kernel), patches from ./patches (the 15 from notALake/linux-zen-atomisp-bin).
#
# The kernel sources (only the two paths we need: atomisp + mt9m114.c) stay in
# a cache, so they are not downloaded again on every build.
# Cache: ~/.cache/atomisp-hp813e/<tag>  (override with ATOMISP_CACHE=...);
# --refresh forces a re-download; when the kernel changes the tag changes and
# the sources are downloaded once.
#
# Usage:  sudo ./install.sh [--kver 7.2.11-zen1-1-zen] [--prepare-only] [--no-firmware] [--tarball|--kernelorg] [--refresh] [--hook]
#
# --hook is the mode used by the pacman hook (see README, "Kernel updates"):
# it checks all installed kernels and rebuilds those without modules,
# re-invoking the script with --kver for each one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="$(uname -r)"
PREPARE_ONLY=0
USE_TARBALL=0
USE_KORG=0
FIRMWARE=1
REFRESH=0
HOOK=0
PATCHSET=15
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

# Kit installed in a stable location: the pacman hook runs as root (without
# SUDO_USER and without knowing where the repo is), so it needs a fixed path.
KIT="/usr/local/share/atomisp-hp813e"
HOOK_FILE="/etc/pacman.d/hooks/75-atomisp-hp813e.hook"

# --- --hook mode: invoked by the pacman hook at the end of a transaction.
#     Checks every installed kernel that has headers and rebuilds the ones
#     without modules, re-invoking this same script with --kver (each run
#     handles ONE kernel: DKMS version cleanup is per-version, so several
#     sequential runs do not step on each other). It is idempotent: if the
#     module already exists for that kernel it does nothing (and if a build
#     fails it exits with a non-zero code and says so).
if [ "$HOOK" = 1 ]; then
  [ "$(id -u)" = 0 ] || { echo "atomisp-hp813e --hook: root required"; exit 1; }
  rc=0; n=0
  for k in $(ls -1 /usr/lib/modules 2>/dev/null | sort -V); do
    [ -e "/usr/lib/modules/$k/build" ] || continue        # no headers: cannot build
    if dkms status 2>/dev/null | grep -qE "^atomisp-hp813e/[^, ]*, $k, [^:]*: installed"; then
      continue                                            # already ready
    fi
    echo "==> hook: kernel $k has no atomisp modules -> rebuilding from zen-kernel"
    n=$((n + 1))
    bash "$0" --kver "$k" || rc=1
  done
  if [ "$n" = 0 ]; then
    echo "==> hook: all installed kernels already have the atomisp-hp813e modules"
  elif [ "$rc" != 0 ]; then
    echo "!! hook: some builds failed, redo them by hand:"
    echo "   sudo $KIT/install.sh"
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
VER="${BASE}-p${PATCHSET}"
DEST="/usr/src/${PKG}-${VER}"
[ "$PREPARE_ONLY" = 1 ] && DEST="${PWD}/${PKG}-${VER}"

echo "==> kernel $KVER  ->  zen-kernel tag $TAG  ->  $DEST"

if [ "$PREPARE_ONLY" = 0 ]; then
  [ "$(id -u)" = 0 ] || { echo "root required (sudo)"; exit 1; }
  for c in dkms git patch make gcc; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 1; }; done
  [ -d "/lib/modules/$KVER/build" ] || { echo "missing headers: pacman -S linux-zen-headers"; exit 1; }

  # --- check dependencies in the headers' .config: atomisp cannot create them itself
  CFG="/lib/modules/$KVER/build/.config"
  miss=0
  for s in VIDEO_DEV MEDIA_PCI_SUPPORT INTEL_SKL_INT3472 IPU_BRIDGE PMIC_OPREGION I2C \
           V4L2_FWNODE IOSF_MBI VIDEOBUF2_VMALLOC VIDEO_V4L2_SUBDEV_API VIDEO_MT9M114 VIDEO_APTINA_PLL V4L2_CCI_I2C; do
    if ! grep -Eq "^CONFIG_${s}=(y|m)" "$CFG"; then echo "   MISSING in the kernel: CONFIG_$s"; miss=1; fi
  done
  [ "$miss" = 0 ] || { echo "ERROR: missing dependencies; an external module cannot resolve them (a rebuilt kernel is required)"; exit 1; }

  # --- stable kit used by the pacman hook (the hook runs as root and does not
  #     know where the repo is): install.sh + patches. When run from the repo
  #     the copy is always refreshed; when run from the kit it skips itself.
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

  # --- pacman hook: on every install/upgrade of a kernel (or its headers)
  #     re-runs the script in --hook mode, which builds the modules for the
  #     kernels that do not have them. This way, after a pacman -Syu you only
  #     need to reboot.
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

# --- sources: only atomisp + mt9m114.c from zen-kernel (same tag as the running kernel)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "$DEST.tmp"' EXIT
export GIT_TERMINAL_PROMPT=0
REPO=https://github.com/zen-kernel/zen-kernel
KSRC="$TMP/git"
WANT_DIR=drivers/staging/media/atomisp
WANT_FILE=drivers/media/i2c/mt9m114.c
WANT_HDR=drivers/media/i2c/aptina-pll.h   # local header included by mt9m114.c (the code is in the kernel's aptina-pll.ko)

# --- source cache: key = kernel tag ($TAG). If run with sudo, use the cache
#     of the user who invoked sudo, so it is shared between runs with and
#     without sudo and does not end up in /root.
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
  # tag tarball on GitHub (~250 MB); extract only the 2 paths we need
  rm -rf "$KSRC"; mkdir -p "$KSRC"
  curl -fL --retry 1 --connect-timeout 15 --progress-bar "$REPO/archive/refs/tags/${TAG}.tar.gz" \
    | tar -xz -C "$KSRC" --strip-components=1 --wildcards "*/$WANT_DIR" "*/$WANT_FILE" "*/$WANT_HDR"
}
fetch_kernelorg() {
  # kernel.org (not GitHub): for atomisp and mt9m114.c the stable x.y.z kernel is
  # identical to the zen tag (verified with git hashes for 7.2.9). Tarball ~150 MB
  # .tar.xz; extract only the 2 paths.
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
    echo "==> downloading sources from zen-kernel ($TAG) via git (90s timeout)..."
    if ! fetch_git; then
      echo "==> git is not responding (GitHub rate limit?): trying the GitHub tarball..."
      if ! fetch_tarball; then
        echo "==> GitHub unavailable: falling back to kernel.org..."
        fetch_kernelorg
      fi
    fi
  fi
  [ -f "$KSRC/$WANT_FILE" ] && [ -d "$KSRC/$WANT_DIR" ] || { echo "ERROR: sources were not downloaded correctly"; exit 1; }

  # --- cache only the paths we need (reusable on the next build)
  if rm -rf "$CSRC" &&
     mkdir -p "$CSRC/$(dirname "$WANT_FILE")" "$CSRC/drivers/staging/media" &&
     cp "$KSRC/$WANT_FILE" "$KSRC/$WANT_HDR" "$CSRC/$(dirname "$WANT_FILE")/" &&
     cp -r "$KSRC/$WANT_DIR" "$CSRC/drivers/staging/media/"; then
    echo "==> sources saved to cache: $CSRC"
    SRC="$CSRC"
  else
    echo "==> warning: cache is not writable ($CSRC), using temporary sources"
    SRC="$KSRC"
  fi
fi

# --- working tree with the same paths as the kernel, so the patches apply as-is
W="$TMP/w"; mkdir -p "$W/drivers/media/i2c" "$W/drivers/staging/media"
cp "$SRC/$WANT_FILE" "$SRC/$WANT_HDR" "$W/drivers/media/i2c/"
cp -r "$SRC/$WANT_DIR" "$W/drivers/staging/media/"

echo "==> applying patches"
for p in "$HERE"/patches/0*.patch; do
  printf '   %s ... ' "$(basename "$p")"
  (cd "$W" && patch -Np1 --no-backup-if-mismatch -s < "$p") && echo ok \
    || { echo "FAILED"; echo "Patches do not apply to $TAG: the driver changed and they need to be adapted."; exit 1; }
done

# --- DKMS layout. Build in "$DEST.tmp" and move to $DEST only when everything
#     is ready: if a cp/sed fails, the previous DKMS entry remains valid with
#     its sources (instead of being left half-done) and dkms autoinstall does
#     not break.
DST="$DEST.tmp"
rm -rf "$DST"; mkdir -p "$DST"
cp -r "$W/drivers/staging/media/atomisp" "$DST/atomisp"
cp "$W/drivers/media/i2c/mt9m114.c" "$W/drivers/media/i2c/aptina-pll.h" "$DST/"
rm -rf "$DST/atomisp/i2c"         # OV2722/GC2235 sensors: not needed for the MT9M114

# atomisp Makefile: no out-of-tree Kconfig -> force obj-m and relative paths
sed -i -e '/^obj-\$(CONFIG_INTEL_ATOMISP) += i2c\/$/d' \
       -e 's/^obj-\$(CONFIG_VIDEO_ATOMISP)/obj-m/' \
       -e 's#\$(srctree)/drivers/staging/media/atomisp/#$(src)/#' \
       "$DST/atomisp/Makefile"

cat > "$DST/Kbuild" <<KB
# external module: atomisp.ko + atomisp_gmin_platform.ko + mt9m114.ko (patched)
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

# --- handling of the DKMS versions already present, for each entry (name/version):
#   (b) old name (variants used over time)          -> entry + sources
#   (a) the version I am about to rebuild           -> entry only ($DEST with the
#        new sources was already prepared above, I do not touch it)
#   (c) /usr/src/<pkg>-<ver> is missing (broken)    -> entry only (there is nothing
#        to remove, the sources are already gone)
#   (d) none of its kernels is installed            -> entry + sources
#   (e) installed on THIS run's kernel ($KVER)      -> entry + sources. It must be
#        removed BEFORE my build: otherwise the .ko files of the two packages end
#        up in the same /lib/modules/$KVER/updates/dkms and, when dkms removes the
#        old one, it deletes the .ko files I just installed.
#   every other entry is kept: it is a fallback. If my build with the new tag
#   fails (patches not applicable, no network, headers not ready) dkms
#   autoinstall can still build it for the new kernel from the sources of the
#   last working version (which are patched anyway), and it covers the other
#   installed kernels.
#   I used to delete EVERYTHING on every run: after each kernel update there
#   was no entry, no sources, no modules left -> the webcam died.
src_missing() { [ ! -f "/usr/src/$1/dkms.conf" ]; }
ks_of() {   # kernels associated with "pkg/ver" (one dkms status line per kernel)
  dkms status 2>/dev/null | grep -F "$1, " | awk -F', ' '{print $2}' | sort -u || true
}
for full in $(dkms status 2>/dev/null | sed -E 's/[:,].*//' | grep '^atomisp-hp813e' | sort -u); do
  m=${full%%/*}; v=${full#*/}
  ks="$(ks_of "$full")"
  why=""; wipe_src=0
  if [ "$m" != "$PKG" ]; then
    why="old name (from the past)"; wipe_src=1
  elif [ "$v" = "$VER" ]; then
    why="this is the version I am about to rebuild"
  elif src_missing "$m-$v"; then
    why="broken entry: sources are missing"
  elif [ -z "$ks" ]; then
    why="entry with no associated kernels"; wipe_src=1
  else
    nalive=0
    for k in $ks; do
      [ -d "/usr/lib/modules/$k" ] || continue
      if [ "$k" = "$KVER" ]; then
        why="installed on the target kernel $KVER"; wipe_src=1; break
      fi
      nalive=$((nalive + 1))
    done
    if [ -z "$why" ] && [ "$nalive" = 0 ]; then
      why="none of its kernels is installed"; wipe_src=1
    fi
  fi
  if [ -z "$why" ]; then
    echo "==> keeping $full (healthy: used as a fallback for other kernels, dkms autoinstall)"
    continue
  fi
  echo "==> removing DKMS entry $full ($why)"
  dkms remove "$full" --all 2>/dev/null || rm -rf "/var/lib/dkms/$m/$v"
  if [ "$wipe_src" = 1 ]; then rm -rf "/usr/src/$m-$v"; fi
done

# orphaned sources: they belong to no live DKMS entry and are not $DEST.
# First verify that dkms really responds: if the command fails (lock, transient
# error) status returns empty and the sweep would delete the sources of entries
# that do exist -> healthy entries left without sources.
if dkms status >/dev/null 2>&1; then
  alive=" "
  for full in $(dkms status 2>/dev/null | sed -E 's/[:,].*//' | grep '^atomisp-hp813e' | sort -u); do
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

dkms add "$PKG/$VER" 2>&1 || true
dkms build   -m "$PKG" -v "$VER" -k "$KVER"
dkms install -m "$PKG" -v "$VER" -k "$KVER" --force

# intel_atomisp2_pm claims the same PCI device as the ISP (the patched kernel
# makes it exclude itself)
cat > /etc/modprobe.d/atomisp-hp813e.conf <<'MP'
# atomisp and intel_atomisp2_pm are alternatives on the same PCI device (ISP, 00:03.0)
blacklist intel_atomisp2_pm
install intel_atomisp2_pm /bin/false
MP

if [ "$FIRMWARE" = 1 ]; then
  # The firmware is provided by the linux-firmware-intel package in
  # /usr/lib/firmware/intel/ipu/ (compressed .zst), and the driver looks for
  # that path first: no need to copy it. Only if the system does not have it
  # (old linux-firmware) do we use the copy included in this directory.
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

# modprobe ALWAYS acts on the running kernel: with --kver (or from the pacman
# hook, which runs before the reboot) the target kernel is not the current one
# and there is nothing to reload; the modules will be used on the next boot.
if [ "$KVER" != "$(uname -r)" ]; then
  echo "==> $KVER: modules built and installed (this is not the running kernel:"
  echo "    they will become active on the next reboot)"
else
  # --- reload the modules right away, so no reboot is needed. BOTH must be
  #     reloaded: mt9m114 is the sensor driver and is often already loaded by
  #     the stock kernel (without flip, without the AE fix) - if that one stays,
  #     the image is upside down and overexposed. If the webcam is open the
  #     rmmod fails: in that case close the program and reload/reboot by hand.
  fail=0
  if lsmod | grep -q '^atomisp '; then
    modprobe -r atomisp 2>/dev/null || fail=1
  fi
  if [ "$fail" = 0 ] && lsmod | grep -q '^mt9m114 '; then
    modprobe -r mt9m114 2>/dev/null || true
  fi
  if [ "$fail" = 0 ] && modprobe atomisp 2>/dev/null; then
    echo "==> modules reloaded (atomisp) - no reboot needed"
  else
    echo "==> failed to reload the modules: close the webcam and then"
    echo "    sudo modprobe -r atomisp mt9m114 && sudo modprobe atomisp   (or reboot)"
  fi
  # verify that mt9m114 is the PATCHED one (updates/dkms) and not the stock kernel one
  case "$(modinfo -n mt9m114 2>/dev/null || true)" in
    */updates/dkms/*) echo "    mt9m114: patched version ($(modinfo -n mt9m114))" ;;
    "")               echo "    mt9m114: not loaded, it will be loaded at boot" ;;
    *)  echo "    WARNING: the mt9m114 in use is the stock kernel one (no flip, no AE fix)"
        echo "      sudo modprobe -r mt9m114 && sudo modprobe mt9m114" ;;
  esac
fi
echo "==> done."
echo "    Check: modinfo atomisp | head -3 ; dmesg | grep -i -E 'atomisp|mt9m114'"
