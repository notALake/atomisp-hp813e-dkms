# atomisp-hp813e-dkms

Patched `atomisp` + `mt9m114` as DKMS modules for HP Pavilion x2 (board 813E)
webcams on linux-zen, instead of a custom rebuilt kernel.

Sources are taken from the zen-kernel tag matching the kernel being built and
patched with the 15-patch set in [`patches/`](patches).

## Requirements

- Arch Linux (or another distribution with DKMS)
- `dkms`, `git`, `patch`, `make`, `gcc`
- the headers of the target kernel (e.g. `linux-zen-headers`)
- `linux-firmware-intel` for the ISP firmware

## Installation

```sh
sudo pacman -S --needed dkms linux-zen-headers git patch base-devel
git clone https://github.com/notALake/atomisp-hp813e-dkms
cd atomisp-hp813e-dkms
sudo ./install.sh
```

`install.sh`:

- downloads the zen-kernel sources matching the target kernel (`uname -r`, or
  `--kver`) and applies `patches/`;
- builds and installs `atomisp.ko`, `atomisp_gmin_platform.ko` and the patched
  `mt9m114.ko` as the DKMS package `atomisp-hp813e`;
- writes `/etc/modprobe.d/atomisp-hp813e.conf` (it disables
  `intel_atomisp2_pm`, which claims the same PCI device as the ISP);
- installs the pacman hook described below;
- copies itself and `patches/` to `/usr/local/share/atomisp-hp813e/`, the copy
  used by the hook;
- reloads the modules, so normally no reboot is needed.

Useful options:

| Option | Meaning |
| --- | --- |
| `--kver <kernel>` | build for another installed kernel (default: the running one) |
| `--prepare-only` | prepare the DKMS sources without installing anything |
| `--refresh` | re-download the sources instead of using the cache |
| `--tarball` / `--kernelorg` | force the GitHub tarball or kernel.org as the source |
| `--no-firmware` | skip the firmware check |

Downloaded sources are cached per kernel tag in
`~/.cache/atomisp-hp813e/<tag>`; set `ATOMISP_CACHE` to use another directory.

If a patch does not apply, the script stops before installing anything.

## DKMS version

The DKMS version is the patch set number, currently `15`, with no kernel
version in it:

```text
atomisp-hp813e/15
```

The DKMS entry is reused for every kernel. Its sources live in
`/usr/src/atomisp-hp813e-15` and are replaced with the sources of the kernel
being built; modules already built for other kernels are not touched.

## Kernel updates

On every run the script installs a pacman hook
(`/etc/pacman.d/hooks/75-atomisp-hp813e.hook`). When a `pacman -Syu` installs or
upgrades a kernel (or its headers), the hook:

1. looks at every `/usr/lib/modules/<kernel>` that has headers (`build/`);
2. for each kernel where `dkms status` does not report `atomisp-hp813e/15` as
   installed, rebuilds it from the matching zen-kernel tag and installs it.

So after a kernel update **you only need to reboot**: the webcam works without
running anything by hand. The hook checks all installed kernels, not only the
running one, so the module is ready before the reboot.

The check is idempotent: if the module is already installed for a kernel, it is
left alone. If a build fails, the hook exits non-zero and the previous healthy
DKMS entries are kept. In that case, or if the hook did not run, rebuild by
hand:

```sh
sudo /usr/local/share/atomisp-hp813e/install.sh
```

Even when the rebuild with a new tag fails (patches not applicable, no
network), the webcam usually still works: Arch's `70-dkms-install` hook rebuilds
the last working version for the new kernel from its patched sources.

## Uninstall

```sh
sudo dkms remove atomisp-hp813e/15 --all
sudo rm -f /etc/modprobe.d/atomisp-hp813e.conf
sudo rm -f /etc/pacman.d/hooks/75-atomisp-hp813e.hook
sudo rm -rf /usr/src/atomisp-hp813e-15 /usr/local/share/atomisp-hp813e
sudo depmod -a
```

## Firmware

`shisp_2401a0_v21.bin` **is not included in this repository**: it is provided by
`linux-firmware-intel` in `/usr/lib/firmware/intel/ipu/` (compressed as `.zst`;
the kernel decompresses it itself) and the driver looks there first.

If the system does not have it, `install.sh` uses the `shisp_2401a0_v21.bin`
copy placed next to the script; if that is missing too it warns and continues.
`--no-firmware` skips this step.

## Color: module parameters

The raw-Bayer -> Intel ISP path has no auto-white-balance algorithm and no
saturation control (no 3A daemon runs on Linux), so the defaults are compiled
into patches 0013 (white balance) and 0015 (saturation). They can also be
changed at runtime.

| parameter | default | meaning |
| --- | --- | --- |
| `wb_r` | 27200 | **blue** gain = 1.66x (the field is called `r` but it is blue: the two fields are swapped in the ISP) |
| `wb_b` | 17720 | **red** gain = 1.08x |
| `saturation` | 180 | saturation, 100 = original matrix, 0 = grayscale |
| `wb_gr` | 16384 | green (Gr) = 1.00x |
| `wb_gb` | 16384 | green (Gb) = 1.00x |
| `wb_integer_bits` | 2 | 16384 = 1.0x |

New values are read the next time the webcam is opened (the ISP stream is
recreated on every STREAMON), so you can try them without recompiling:

```sh
echo 27200 | sudo tee /sys/module/atomisp/parameters/wb_r
echo 17720 | sudo tee /sys/module/atomisp/parameters/wb_b
echo 180   | sudo tee /sys/module/atomisp/parameters/saturation
```

To make them permanent, change them in `patches/0013-...` (`wb_r`, `wb_b`) and
`patches/0015-...` (`saturation`), then run `sudo ./install.sh` again.

## Credits

The atomisp/mt9m114 fix and its DKMS packaging were developed with the help of
**GLM-5.3** and **DeepSeek V4.1 Flash**.
