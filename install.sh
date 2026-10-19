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
# Uso:  sudo ./install.sh [--kver 7.2.11-zen1-1-zen] [--prepare-only] [--no-firmware] [--tarball|--kernelorg] [--refresh] [--hook]
#
# --hook e' la modalita' usata dall'hook pacman (vedi README, "Aggiornamenti del
# kernel"): controlla tutti i kernel installati e ricostruisce quelli senza modulo,
# reinvocando lo script con --kver per ciascuno.
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
    *) echo "opzione sconosciuta: $1"; exit 1 ;;
  esac
done

# Kit installato in una posizione stabile: l'hook pacman gira come root (senza
# SUDO_USER e senza sapere dove sia la repo), quindi deve avere un path fisso.
KIT="/usr/local/share/atomisp-hp813e"
HOOK_FILE="/etc/pacman.d/hooks/75-atomisp-hp813e.hook"

# --- modalita' --hook: lanciata dall'hook pacman a fine transazione.  Controlla ogni
#     kernel installato che ha gli header e ricostruisce quelli senza modulo,
#     reinvocando questo stesso script con --kver (ogni run fa UN kernel: la pulizia
#     delle versioni DKMS e' per-versione, quindi piu' run in sequenza non si
#     pestano i piedi).  Usata dal hook lascia il modulo invariato: e' idempotente.
if [ "$HOOK" = 1 ]; then
  [ "$(id -u)" = 0 ] || { echo "atomisp-hp813e --hook: serve root"; exit 1; }
  rc=0; n=0
  for k in $(ls -1 /usr/lib/modules 2>/dev/null | sort -V); do
    [ -e "/usr/lib/modules/$k/build" ] || continue        # niente header: non si puo' costruire
    if dkms status 2>/dev/null | grep -qE "^atomisp-hp813e/[^, ]*, $k, [^:]*: installed"; then
      continue                                            # gia' pronto
    fi
    echo "==> hook: kernel $k senza moduli atomisp -> ricostruisco da zen-kernel"
    n=$((n + 1))
    bash "$0" --kver "$k" || rc=1
  done
  if [ "$n" = 0 ]; then
    echo "==> hook: tutti i kernel installati hanno gia' i moduli atomisp-hp813e"
  elif [ "$rc" != 0 ]; then
    echo "!! hook: qualche build non e' riuscita, rifalla a mano:"
    echo "   sudo $KIT/install.sh"
  fi
  exit $rc
fi

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

  # --- kit stabile usato dall'hook pacman (l'hook gira come root e non sa dove sia
  #     la repo): install.sh + patches.  Se lanciato dalla repo la copia e'
  #     sempre aggiornata, se lanciato dal kit si salta da solo.
  if [ "$(readlink -f "$HERE")" != "$(readlink -f "$KIT")" ]; then
    mkdir -p "$KIT"
    rm -rf "$KIT/patches"
    cp -f "$HERE/install.sh" "$KIT/install.sh"
    chmod 755 "$KIT/install.sh"
    cp -r "$HERE/patches" "$KIT/patches"
    if [ -f "$HERE/shisp_2401a0_v21.bin" ] && [ ! -f "$KIT/shisp_2401a0_v21.bin" ]; then
      cp -f "$HERE/shisp_2401a0_v21.bin" "$KIT/"
    fi
    echo "==> kit installato in $KIT (e' la copia che usa l'hook pacman)"
  fi

  # --- hook pacman: a ogni install/upgrade di kernel (o dei suoi header) rilancia
  #     lo script in modalita' --hook, che costruisce i moduli per i kernel che non
  #     li hanno.  Cosi' dopo un pacman -Syu basta riavviare.
  mkdir -p "$(dirname "$HOOK_FILE")"
  cat > "$HOOK_FILE" <<'HOOK'
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
Exec = /usr/local/share/atomisp-hp813e/install.sh --hook
HOOK
  echo "==> hook pacman scritto: $HOOK_FILE"
fi

# --- sorgenti: solo atomisp + mt9m114.c da zen-kernel (stesso tag del kernel in esecuzione)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "$DEST.tmp"' EXIT
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

# --- layout DKMS.  Costruisco in "$DEST.tmp" e sposto in $DEST solo quando e' tutto
#     pronto: se un cp/sed fallisce l'entry DKMS precedente resta valida coi suoi
#     sorgenti (invece di restare a meta') e dkms autoinstall non si rompe.
DST="$DEST.tmp"
rm -rf "$DST"; mkdir -p "$DST"
cp -r "$W/drivers/staging/media/atomisp" "$DST/atomisp"
cp "$W/drivers/media/i2c/mt9m114.c" "$W/drivers/media/i2c/aptina-pll.h" "$DST/"
rm -rf "$DST/atomisp/i2c"         # sensori OV2722/GC2235: non servono per l'MT9M114

# Makefile di atomisp: niente Kconfig fuori dall'albero -> forza obj-m e path relativi
sed -i -e '/^obj-\$(CONFIG_INTEL_ATOMISP) += i2c\/$/d' \
       -e 's/^obj-\$(CONFIG_VIDEO_ATOMISP)/obj-m/' \
       -e 's#\$(srctree)/drivers/staging/media/atomisp/#$(src)/#' \
       "$DST/atomisp/Makefile"

cat > "$DST/Kbuild" <<KB
# modulo esterno: atomisp.ko + atomisp_gmin_platform.ko + mt9m114.ko (patchato)
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
  echo "==> sorgenti DKMS pronti in $DEST (--prepare-only: non installo nulla)"; exit 0
fi

# --- gestione delle versioni DKMS gia' presenti, per ogni entry (nome/versione):
#   (b) nome vecchio (varianti usate nel tempo)      -> entry + sorgenti
#   (a) e' la versione che sto per ricostruire       -> solo l'entry ($DEST con i
#        sorgenti nuovi e' gia' stato preparato qui sopra, non lo tocco)
#   (c) manca /usr/src/<pkg>-<ver> (entry rotta)    -> solo l'entry (non c'e' niente
#        da togliere, i sorgenti non ci sono gia')
#   (d) nessuno dei suoi kernel e' installato        -> entry + sorgenti
#   (e) installata sul kernel di QUESTA run ($KVER)  -> entry + sorgenti.  Va tolta
#        PRIMA della mia build: altrimenti i .ko dei due pacchetti finiscono negli
#        stessi /lib/modules/$KVER/updates/dkms e, quando dkms rimuove quella vecchia,
#        cancella i .ko appena installati da me.
#   ogni altra entry resta: e' un fallback.  Se la mia build col tag nuovo fallisce
#   (patch non applicabili, rete assente, header non pronti) dkms autoinstall puo'
#   costruirla comunque per il kernel nuovo dai sorgenti dell'ultima versione
#   funzionante (che sono comunque patchati), e copre gli altri kernel installati.
#   Prima cancellavo TUTTO ad ogni run: ad ogni aggiornamento del kernel restava
#   niente entry, niente sorgenti, niente moduli -> la webcam moriva.
src_missing() { [ ! -f "/usr/src/$1/dkms.conf" ]; }
ks_of() {   # kernel associati a "pkg/ver" (una riga di dkms status per kernel)
  dkms status 2>/dev/null | grep -F "$1, " | awk -F', ' '{print $2}' | sort -u || true
}
for full in $(dkms status 2>/dev/null | sed -E 's/[:,].*//' | grep '^atomisp-hp813e' | sort -u); do
  m=${full%%/*}; v=${full#*/}
  ks="$(ks_of "$full")"
  why=""; wipe_src=0
  if [ "$m" != "$PKG" ]; then
    why="nome vecchio (del passato)"; wipe_src=1
  elif [ "$v" = "$VER" ]; then
    why="e' la versione che sto per ricostruire"
  elif src_missing "$m-$v"; then
    why="entry rotta: mancano i sorgenti"
  elif [ -z "$ks" ]; then
    why="entry senza kernel associati"; wipe_src=1
  else
    nalive=0
    for k in $ks; do
      [ -d "/usr/lib/modules/$k" ] || continue
      if [ "$k" = "$KVER" ]; then
        why="installata sul kernel bersaglio $KVER"; wipe_src=1; break
      fi
      nalive=$((nalive + 1))
    done
    if [ -z "$why" ] && [ "$nalive" = 0 ]; then
      why="nessuno dei suoi kernel e' installato"; wipe_src=1
    fi
  fi
  if [ -z "$why" ]; then
    echo "==> tengo $full (sana: serve da fallback per gli altri kernel, dkms autoinstall)"
    continue
  fi
  echo "==> rimuovo entry DKMS $full ($why)"
  dkms remove "$full" --all 2>/dev/null || rm -rf "/var/lib/dkms/$m/$v"
  if [ "$wipe_src" = 1 ]; then rm -rf "/usr/src/$m-$v"; fi
done

# sorgenti orfane: non appartengono a nessuna entry DKMS viva e non sono $DEST.
# Prima verifico che dkms risponda davvero: se il comando fallisce (lock, errore
# transitorio) status torna vuoto e la sweep cancellerebbe i sorgenti di entry che
# invece esistono -> entry sane rimaste senza sorgenti.
if dkms status >/dev/null 2>&1; then
  alive=" "
  for full in $(dkms status 2>/dev/null | sed -E 's/[:,].*//' | grep '^atomisp-hp813e' | sort -u); do
    alive="$alive${full%%/*}-${full#*/} "
  done
  alive="$alive${DEST##*/} ${DEST##*/}.tmp "
  for d in /usr/src/atomisp-hp813e*; do
    [ -e "$d" ] || continue
    case "$alive" in *" ${d##*/} "*) continue ;; esac
    echo "==> rimuovo sorgenti orfane $d"; rm -rf "$d"
  done
else
  echo "==> attenzione: dkms status non risponde, salto la pulizia delle sorgenti orfane"
fi

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

# modprobe agisce SEMPRE sul kernel in esecuzione: con --kver (o dall'hook pacman, che
# gira prima del riavvio) il kernel bersaglio non e' quello corrente e non c'e' niente
# da ricaricare, i moduli verranno usati al prossimo avvio.
if [ "$KVER" != "$(uname -r)" ]; then
  echo "==> $KVER: moduli costruiti e installati (non e' il kernel in esecuzione:"
  echo "    diventeranno attivi al prossimo riavvio)"
else
  # --- ricarica i moduli subito, cosi' non serve il riavvio.  Devono ricaricarli TUTTI E
  #     DUE: mt9m114 e' il driver del sensore e viene spesso gia' caricato dal kernel stock
  #     (senza flip, senza il fix AE) - se resta quello, l'immagine e' capovolta e
  #     sovraesposta.  Se la webcam e' aperta il rmmod fallisce: in quel caso
  #     chiudi il programma e ricarica/riavvia a mano.
  fail=0
  if lsmod | grep -q '^atomisp '; then
    modprobe -r atomisp 2>/dev/null || fail=1
  fi
  if [ "$fail" = 0 ] && lsmod | grep -q '^mt9m114 '; then
    modprobe -r mt9m114 2>/dev/null || true
  fi
  if [ "$fail" = 0 ] && modprobe atomisp 2>/dev/null; then
    echo "==> moduli ricaricati (atomisp) - nessun riavvio necessario"
  else
    echo "==> non sono riuscito a ricaricare i moduli: chiudi la webcam e poi"
    echo "    sudo modprobe -r atomisp mt9m114 && sudo modprobe atomisp   (oppure riavvia)"
  fi
  # verifica che mt9m114 sia quello PATCHATO (updates/dkms) e non quello del kernel stock
  case "$(modinfo -n mt9m114 2>/dev/null || true)" in
    */updates/dkms/*) echo "    mt9m114: versione patchata ($(modinfo -n mt9m114))" ;;
    "")               echo "    mt9m114: non caricato, si carichera' all'avvio" ;;
    *)  echo "    ATTENZIONE: mt9m114 in uso e' quello del kernel stock (senza flip, senza il fix AE)"
        echo "      sudo modprobe -r mt9m114 && sudo modprobe mt9m114" ;;
  esac
fi
echo "==> fatto."
echo "    Verifica: modinfo atomisp | head -3 ; dmesg | grep -i -E 'atomisp|mt9m114'"
