# atomisp-hp813e-dkms

atomisp + mt9m114 (with the 15 patches from notALake/linux-zen-atomisp-bin) as
DKMS modules, instead of a rebuilt linux-zen kernel.

    sudo pacman -S dkms linux-zen-headers git patch
    sudo ./install.sh

- Downloads the zen-kernel tag matching the running kernel (`uname -r`). The
  downloaded sources stay in cache (`~/.cache/atomisp-hp813e/<tag>`) and are not
  downloaded again on later builds; `--refresh` re-downloads them,
  `ATOMISP_CACHE=...` changes the cache directory.
- If the kernel version changes (even just 7.2.11 -> 7.2.12), the pacman hook
  handles it (see below); if for some reason it does not run, run
  `sudo ./install.sh` again. The DKMS package contains the sources for ONE
  version.
- If a patch does not apply, the script stops and installs nothing.
- At the end of the installation the script reloads the modules by itself. If
  the webcam is open, the reload fails: close the program and use
  `sudo modprobe -r atomisp && sudo modprobe atomisp` (or reboot).
- Secure Boot / lockdown: the modules must be signed (MOK key in
  `/etc/dkms/framework.conf`).
- Uninstall: `sudo dkms remove atomisp-hp813e/<ver> --all; sudo rm /etc/modprobe.d/atomisp-hp813e.conf`
  (and to remove the hook: `sudo rm /etc/pacman.d/hooks/75-atomisp-hp813e.hook`)

## Kernel updates

On every installation the script also installs a pacman hook
(`/etc/pacman.d/hooks/75-atomisp-hp813e.hook`). At the end of a `pacman -Syu`
that installs or upgrades a kernel (or its headers) the hook:

1. looks at every `/usr/lib/modules/<kernel>` that has headers (`build/`);
2. if `dkms status` does not report the module installed for that kernel, it
   rebuilds it from scratch from the matching zen-kernel tag and installs it.
   It is an idempotent check: if the module is already there it does nothing
   (and then the script, in its normal run, keeps the healthy DKMS versions of
   other kernels as a fallback).

So after a kernel update **you only need to reboot**: the webcam works without
running anything by hand. The hook looks at all installed kernels, not just the
running one, so it builds the module before the reboot too.

Even if the rebuild with the new tag fails (patches not applicable, no network)
the webcam usually still works: the healthy DKMS versions that remain are kept,
and `dkms autoinstall` (Arch's `70-dkms-install` hook) rebuilds them for the new
kernel from the sources of the last working version, which are patched anyway.

If the automatic rebuild fails (no network, patches not applicable to the new
tag, missing headers) it says so in the pacman output and you just run it again
by hand:

    sudo /usr/local/share/atomisp-hp813e/install.sh

The kit (`install.sh` + `patches/`) is copied to
`/usr/local/share/atomisp-hp813e/` because the hook must not depend on the
repository location: running `./install.sh` from the repo always refreshes the
copy.

## Firmware

`shisp_2401a0_v21.bin` **is not included in the repo**: it is provided by the
`linux-firmware-intel` package in `/usr/lib/firmware/intel/ipu/` (compressed as
`.zst`; the kernel decompresses it itself) and the driver looks for that path
first.

If the system does not have it, `install.sh` uses the `shisp_2401a0_v21.bin`
copy placed next to the script; if that is missing too it warns and continues.
`--no-firmware` skips this step.

## Color: module parameters

The raw-Bayer -> Intel ISP path has no auto-white-balance algorithm and no
saturation control (no 3A daemon runs on Linux), so the defaults are compiled
into patches 0013 (white balance) and 0015 (saturation). They can also be
changed at runtime.

| parameter | default | meaning |
|---|---|---|
| `wb_r` | 27200 | **blue** gain = 1.66x (the field is called `r` but it is blue: the two fields are swapped in the ISP) |
| `wb_b` | 17720 | **red** gain = 1.08x |
| `saturation` | 180 | saturation, 100 = original matrix, 0 = grayscale |
| `wb_gr` | 16384 | green (Gr) = 1.00x |
| `wb_gb` | 16384 | green (Gb) = 1.00x |
| `wb_integer_bits` | 2 | 16384 = 1.0x |

New values are read the next time the webcam is opened (the ISP stream is
recreated on every STREAMON), so you can try them without recompiling:

    echo 27200 | sudo tee /sys/module/atomisp/parameters/wb_r
    echo 17720 | sudo tee /sys/module/atomisp/parameters/wb_b
    echo 180   | sudo tee /sys/module/atomisp/parameters/saturation

To make them permanent, change them in `patches/0013-...` (`wb_r`, `wb_b`) and
`patches/0015-...` (`saturation`), then run `sudo ./install.sh` again.
