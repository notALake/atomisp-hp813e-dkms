# atomisp-hp813e-dkms

atomisp + mt9m114 (con le 15 patch di notALake/linux-zen-atomisp-bin) come moduli DKMS,
al posto di un kernel linux-zen ricompilato.

    sudo pacman -S dkms linux-zen-headers git patch
    sudo ./install.sh

- Scarica da zen-kernel il tag che corrisponde al kernel in esecuzione (`uname -r`).
  I sorgenti scaricati restano in cache (`~/.cache/atomisp-hp813e/<tag>`) e non vengono
  riscaricati alle build successive; `--refresh` li riscarica, `ATOMISP_CACHE=...` cambia
  la cartella della cache.
- Se cambia la versione del kernel (anche solo 7.2.11 -> 7.2.12) rilancia `sudo ./install.sh`:
  il pacchetto DKMS contiene i sorgenti di UNA versione.
- Se una patch non si applica, lo script si ferma e non installa nulla.
- A fine installazione lo script ricarica da solo i moduli. Se la webcam e' aperta il
  ricaricamento non riesce: chiudi il programma e usa
  `sudo modprobe -r atomisp && sudo modprobe atomisp` (o riavvia).
- Secure Boot / lockdown: i moduli vanno firmati (chiave MOK in /etc/dkms/framework.conf).
- Disinstallare: `sudo dkms remove atomisp-hp813e/<ver> --all; sudo rm /etc/modprobe.d/atomisp-hp813e.conf`

## Firmware

`shisp_2401a0_v21.bin` **non e' incluso nel repo**: lo fornisce il pacchetto
`linux-firmware-intel` in `/usr/lib/firmware/intel/ipu/` (compresso `.zst`, il kernel lo
decomprime da solo) e il driver cerca proprio quel path per primo.

Se il sistema non ce l'ha, `install.sh` usa la copia `shisp_2401a0_v21.bin` messa accanto
allo script; se non c'e' nemmeno quella avverte e va avanti. `--no-firmware` salta il passo.

## Colore: parametri del modulo

Il percorso raw-Bayer -> ISP Intel non ha nessun algoritmo di auto-white-balance e nessun
controllo di saturazione (su Linux non gira nessun demone 3A), quindi i default sono
compilati nelle patch 0013 (bilanciamento del bianco) e 0015 (saturazione).
Sono anche modificabili a runtime.

| parametro | default | significato |
|---|---|---|
| `wb_r` | 27200 | guadagno **blu** = 1.66x (il campo si chiama `r` ma e' il blu: nell'ISP i due campi sono scambiati) |
| `wb_b` | 15600 | guadagno **rosso** = 0.95x |
| `saturation` | 180 | saturazione, 100 = matrice originale, 0 = scala di grigi |
| `wb_gr` | 16384 | verde (Gr) = 1.00x |
| `wb_gb` | 16384 | verde (Gb) = 1.00x |
| `wb_integer_bits` | 2 | 16384 = 1.0x |

I valori nuovi si leggono alla prossima apertura della webcam (lo stream ISP viene ricreato
a ogni STREAMON), quindi si prova senza ricompilare:

    echo 27200 | sudo tee /sys/module/atomisp/parameters/wb_r
    echo 15600 | sudo tee /sys/module/atomisp/parameters/wb_b
    echo 180   | sudo tee /sys/module/atomisp/parameters/saturation

Per renderli permanenti vanno cambiati in `patches/0013-...` (`wb_r`, `wb_b`) e
`patches/0015-...` (`saturation`), poi si rilancia `sudo ./install.sh`.
