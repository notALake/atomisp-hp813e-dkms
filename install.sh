#!/usr/bin/env bash
# Costruisce atomisp + mt9m114 (patchati) come moduli DKMS per il kernel zen in uso,
# senza ricompilare il kernel. Sorgenti presi da zen-kernel (stesso tag del kernel
# in esecuzione), patch da ./patches (le 15 di notALake/linux-zen-atomisp-bin).
#
# I sorgenti del kernel (solo i due percorsi che servono: atomisp + mt9m114.c)
# restano in una cache, quindi non vengono riscaricati ad ogni build.
# Cache: ~/.cache/atomisp-hp813e/<tag>  (override con ATOMISP_CACHE=...);
# --refresh forza il riscaricamento, cambiando kernel il tag cambia e si scarica
# una volta sola.
#
# Uso:  sudo ./install.sh [--kver 7.2.11-zen1-1-zen] [--prepare-only] [--no-firmware] [--tarball|--kernelorg] [--refresh]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="$(uname -r)"
PREPARE_ONLY=0
USE_TARBALL=0
USE_KORG=0
FIRMWARE=1
REFRESH=0
PATCHSET=15
while [ $# -gt 0 ]; do
  case "$1" in
    --kver) KVER="$2"; shift 2 ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --no-firmware) FIRMWARE=0; shift ;;
    --tarball) USE_TARBALL=1; shift ;;
    --kernelorg) USE_KORG=1; shift ;;
    --refresh) REFRESH=1; shift ;;
    *) echo "opzione sconosciuta: $1"; exit 1 ;;
  esac
done

# --- 7.2.11-zen1-1-zen  ->  base=7.2.11  zen=zen1  (anche "7.2.zen1-1-zen" per le x.y.0)
if [[ "$KVER" =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?)[.-](zen[0-9]+) ]]; then
  BASE="${BASH_REMATCH[1]}"; ZEN="${BASH_REMATCH[3]}"
else
  echo "ERRORE: '$KVER' non sembra un kernel linux-zen (atteso es. 7.2.11-zen1-1-zen)"; exit 1
fi
TAG="v${BASE}-${ZEN}"
PKG="atomisp-hp813e"
VER="${BASE}-p${PATCHSET}"
DEST="/usr/src/${PKG}-${VER}"
[ "$PREPARE_ONLY" = 1 ] && DEST="${PWD}/${PKG}-${VER}"

echo "==> kernel $KVER  ->  zen-kernel tag $TAG  ->  $DEST"

if [ "$PREPARE_ONLY" = 0 ]; then
  [ "$(id -u)" = 0 ] || { echo "serve root (sudo)"; exit 1; }
  for c in dkms git patch make gcc; do command -v "$c" >/dev/null || { echo "manca: $c"; exit 1; }; done
  [ -d "/lib/modules/$KVER/build" ] || { echo "mancano gli header: pacman -S linux-zen-headers"; exit 1; }

  # --- controllo dipendenze nel .config degli header: atomisp non le puo' creare da solo
  CFG="/lib/modules/$KVER/build/.config"
  miss=0
  for s in VIDEO_DEV MEDIA_PCI_SUPPORT INTEL_SKL_INT3472 IPU_BRIDGE PMIC_OPREGION I2C \
           V4L2_FWNODE IOSF_MBI VIDEOBUF2_VMALLOC VIDEO_V4L2_SUBDEV_API VIDEO_MT9M114 VIDEO_APTINA_PLL V4L2_CCI_I2C; do
    if ! grep -Eq "^CONFIG_${s}=(y|m)" "$CFG"; then echo "   MANCA nel kernel: CONFIG_$s"; miss=1; fi
  done
  [ "$miss" = 0 ] || { echo "ERRORE: dipendenze mancanti, un modulo esterno non puo' risolverle (serve kernel ricompilato)"; exit 1; }
fi

# --- sorgenti: solo atomisp + mt9m114.c da zen-kernel (stesso tag del kernel in esecuzione)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_TERMINAL_PROMPT=0
REPO=https://github.com/zen-kernel/zen-kernel
KSRC="$TMP/git"
WANT_DIR=drivers/staging/media/atomisp
WANT_FILE=drivers/media/i2c/mt9m114.c
WANT_HDR=drivers/media/i2c/aptina-pll.h   # header locale incluso da mt9m114.c (il codice e' in aptina-pll.ko del kernel)

# --- cache dei sorgenti: chiave = tag del kernel ($TAG).  Se lanciato con sudo
#     uso la cache dell'utente che ha invocato sudo, cosi' e' condivisa fra run
#     con e senza sudo e non finisce in /root.
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
  # HTTP/1.1 + timeout: su alcune reti HTTP/2 o IPv6 fanno restare git appeso senza output
  timeout 90 git -c http.version=HTTP/1.1 clone --progress --filter=blob:none --no-checkout \
      --depth 1 --branch "$TAG" "$REPO" "$KSRC" &&
  git -C "$KSRC" sparse-checkout set --no-cone "/$WANT_DIR/" "/$WANT_FILE" "/$WANT_HDR" &&
  timeout 120 git -c http.version=HTTP/1.1 -C "$KSRC" checkout
}
fetch_tarball() {
  # tarball del tag su GitHub (~250 MB), estraggo solo i 2 percorsi che servono
  rm -rf "$KSRC"; mkdir -p "$KSRC"
  curl -fL --retry 1 --connect-timeout 15 --progress-bar "$REPO/archive/refs/tags/${TAG}.tar.gz" \
    | tar -xz -C "$KSRC" --strip-components=1 --wildcards "*/$WANT_DIR" "*/$WANT_FILE" "*/$WANT_HDR"
}
fetch_kernelorg() {
  # kernel.org (non GitHub): per atomisp e mt9m114.c il kernel stable x.y.z e' identico al tag zen
  # (verificato con gli hash git per 7.2.9). Tarball ~150 MB .tar.xz, estraggo solo i 2 percorsi.
  local major="${BASE%%.*}" ver="$BASE"
  local url="${KERNELORG_URL:-https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${ver}.tar.xz}"
  rm -rf "$KSRC"; mkdir -p "$KSRC"
  curl -fL --retry 2 --connect-timeout 15 --progress-bar "$url" \
    | tar -xJ -C "$KSRC" --strip-components=1 --wildcards "*/$WANT_DIR" "*/$WANT_FILE" "*/$WANT_HDR"
}

if [ "$REFRESH" = 0 ] && cache_ok; then
  echo "==> uso i sorgenti in cache: $CSRC"
  echo "    (--refresh per riscaricarli, ATOMISP_CACHE per cambiare la cache)"
  SRC="$CSRC"
else
  if [ "$USE_KORG" = 1 ]; then
    echo "==> scarico i sorgenti $BASE da kernel.org (solo atomisp + mt9m114)..."
    fetch_kernelorg
  elif [ "$USE_TARBALL" = 1 ]; then
    echo "==> scarico il tarball di $TAG da GitHub (solo atomisp + mt9m114)..."
    fetch_tarball
  else
    echo "==> scarico i sorgenti da zen-kernel ($TAG) via git (timeout 90s)..."
    if ! fetch_git; then
      echo "==> git non risponde (rate limit GitHub?): provo il tarball GitHub..."
      if ! fetch_tarball; then
        echo "==> GitHub non disponibile: ripiego su kernel.org..."
        fetch_kernelorg
      fi
    fi
  fi
  [ -f "$KSRC/$WANT_FILE" ] && [ -d "$KSRC/$WANT_DIR" ] || { echo "ERRORE: sorgenti non scaricati correttamente"; exit 1; }

  # --- salvo in cache i soli percorsi che servono (riusabili alla prossima build)
  if rm -rf "$CSRC" &&
     mkdir -p "$CSRC/$(dirname "$WANT_FILE")" "$CSRC/drivers/staging/media" &&
     cp "$KSRC/$WANT_FILE" "$KSRC/$WANT_HDR" "$CSRC/$(dirname "$WANT_FILE")/" &&
     cp -r "$KSRC/$WANT_DIR" "$CSRC/drivers/staging/media/"; then
    echo "==> sorgenti salvati in cache: $CSRC"
    SRC="$CSRC"
  else
    echo "==> attenzione: cache non scrivibile ($CSRC), uso i sorgenti temporanei"
    SRC="$KSRC"
  fi
fi

# --- albero di lavoro con gli stessi path del kernel, cosi' le patch si applicano as-is
W="$TMP/w"; mkdir -p "$W/drivers/media/i2c" "$W/drivers/staging/media"
cp "$SRC/$WANT_FILE" "$SRC/$WANT_HDR" "$W/drivers/media/i2c/"
cp -r "$SRC/$WANT_DIR" "$W/drivers/staging/media/"

echo "==> applico le patch"
for p in "$HERE"/patches/0*.patch; do
  printf '   %s ... ' "$(basename "$p")"
  (cd "$W" && patch -Np1 --no-backup-if-mismatch -s < "$p") && echo ok \
    || { echo "FALLITA"; echo "Le patch non si applicano a $TAG: il driver e' cambiato, vanno riadattate."; exit 1; }
done

# --- layout DKMS
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$W/drivers/staging/media/atomisp" "$DEST/atomisp"
cp "$W/drivers/media/i2c/mt9m114.c" "$W/drivers/media/i2c/aptina-pll.h" "$DEST/"
rm -rf "$DEST/atomisp/i2c"         # sensori OV2722/GC2235: non servono per l'MT9M114

# Makefile di atomisp: niente Kconfig fuori dall'albero -> forza obj-m e path relativi
sed -i -e '/^obj-\$(CONFIG_INTEL_ATOMISP) += i2c\/$/d' \
       -e 's/^obj-\$(CONFIG_VIDEO_ATOMISP)/obj-m/' \
       -e 's#\$(srctree)/drivers/staging/media/atomisp/#$(src)/#' \
       "$DEST/atomisp/Makefile"

cat > "$DEST/Kbuild" <<KB
# modulo esterno: atomisp.ko + atomisp_gmin_platform.ko + mt9m114.ko (patchato)
obj-m += atomisp/
obj-m += mt9m114.o
KB

cat > "$DEST/dkms.conf" <<DK
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

if [ "$PREPARE_ONLY" = 1 ]; then
  echo "==> sorgenti DKMS pronti in $DEST (--prepare-only: non installo nulla)"; exit 0
fi

# --- rimuovi versioni DKMS precedenti (inclusa la stessa versione, se un build e' fallito)
for old in $(dkms status -m "$PKG" 2>/dev/null | sed -E 's/^[^/]*\/([^,:]+)[,:].*/\1/' | sort -u); do
  echo "==> rimuovo versione DKMS precedente $old"; dkms remove "$PKG/$old" --all || true
done

dkms add "$PKG/$VER" 2>&1 || true
dkms build   -m "$PKG" -v "$VER" -k "$KVER"
dkms install -m "$PKG" -v "$VER" -k "$KVER" --force

# intel_atomisp2_pm si prende lo stesso device PCI dell'ISP (nel kernel patchato si auto-esclude)
cat > /etc/modprobe.d/atomisp-hp813e.conf <<'MP'
# atomisp e intel_atomisp2_pm sono alternativi sullo stesso device PCI (ISP, 00:03.0)
blacklist intel_atomisp2_pm
install intel_atomisp2_pm /bin/false
MP

if [ "$FIRMWARE" = 1 ]; then
  # Il firmware e' fornito dal pacchetto linux-firmware-intel in
  # /usr/lib/firmware/intel/ipu/ (compresso .zst), e il driver cerca proprio
  # quel path per primo: non serve copiarlo.  Solo se il sistema non ce l'ha
  # (linux-firmware vecchio) uso la copia inclusa in questa cartella.
  FW_NEW=/usr/lib/firmware/intel/ipu/shisp_2401a0_v21.bin
  FW_NEW_ZST=$FW_NEW.zst
  FW_LEGACY=/lib/firmware/shisp_2401a0_v21.bin
  if [ -f "$HERE/shisp_2401a0_v21.bin" ]; then
    install -Dm644 "$HERE/shisp_2401a0_v21.bin" "$FW_LEGACY"
    echo "==> firmware installato da questa cartella in $FW_LEGACY"
  elif [ -f "$FW_NEW" ]; then
    echo "==> firmware gia' presente ($FW_NEW)"
  elif [ -f "$FW_NEW_ZST" ]; then
    echo "==> firmware gia' presente ($FW_NEW_ZST, il kernel lo decomprime da solo)"
    # copia anche al path senza prefisso, per i kernel che cercano solo quello
    if [ ! -e "$FW_LEGACY" ] && command -v zstd >/dev/null; then
      zstd -dc "$FW_NEW_ZST" > "$FW_LEGACY" && echo "    (copiato anche in $FW_LEGACY)"
    fi
  else
    echo "!! ATTENZIONE: firmware shisp_2401a0_v21.bin non trovato."
    echo "   Installa il pacchetto linux-firmware-intel."
  fi
fi
depmod "$KVER"

# --- ricarica i moduli subito, cosi' non serve il riavvio (se la webcam e' in uso
#     il rmmod fallisce: in quel caso chiudi il programma e ricarica/riavvia a mano)
if lsmod | grep -q '^atomisp '; then
  if modprobe -r atomisp 2>/dev/null && modprobe atomisp 2>/dev/null; then
    echo "==> moduli ricaricati (atomisp) - nessun riavvio necessario"
  else
    echo "==> atomisp era in uso: chiudi la webcam e poi"
    echo "    sudo modprobe -r atomisp && sudo modprobe atomisp   (oppure riavvia)"
  fi
else
  echo "==> moduli non caricati: si caricheranno all'avvio o con 'sudo modprobe atomisp'"
fi
echo "==> fatto."
echo "    Verifica: modinfo atomisp | head -3 ; dmesg | grep -i -E 'atomisp|mt9m114'"
