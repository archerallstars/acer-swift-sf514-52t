# Acer Swift SF514-52T

Out-of-tree device fixes for this Kaby Lake laptop. Anything that is
not yet in the upstream kernel or related projects lives here, as a
**layer on the base system** — whether that base is a mutable root or
an ostree/immutable image.

Each fix is a `scripts-<area>-fix/` tree with its own install,
uninstall, and verify. Most installers write `/etc` and `/var`.
The iGPU fix only changes bootloader kernel arguments. None of
them write `/usr`, so the same layer works on Fedora Atomic and
on a mutable distro.

## Hardware

| | |
| --- | --- |
| Machine | Acer Swift SF514-52T |
| Board | Carlsberg_KL |
| BIOS | V1.11 |
| CPU | Intel Core i5-8250U (Kaby Lake-U) |
| iGPU | Intel UHD Graphics 620 (Kaby Lake-R GT2), PCI `8086:5917` |
| Audio | Realtek ALC255, PCI `8086:9d71` subsystem `1025:1225` |
| Fingerprint | EgisTec `1c7a:0570` press pad below the arrow keys (serial `W70D612F`, USB string `070D612F`, bcdDevice 10.41) |

## Fixes

| Area | Page | Status |
| --- | --- | --- |
| Audio (Intel AVS + Realtek ALC255) | [`scripts-audio-fix/README.md`](scripts-audio-fix/README.md) | shipped |
| Fingerprint (EgisTec 1c7a:0570) | [`scripts-fingerprint-fix/README.md`](scripts-fingerprint-fix/README.md) | live-tested on this chassis |
| iGPU (i915 display C-states) | [`scripts-igpu-fix/README.md`](scripts-igpu-fix/README.md) | live-tested on this chassis |
| BIOS Setup access (Limine + Insyde F2 hang) | [`scripts-bios-fix/README.md`](scripts-bios-fix/README.md) | documented + recovery helper |

New work goes in a new `scripts-<area>-fix/` directory. Do not dump
unrelated fixes into `scripts-audio-fix/`.

## How a fix layers

- Prefer `/etc` and `/var`. If the payload normally lives under `/usr`,
  overlay or bind it from `/var`. The iGPU fix is bootloader kargs
  (`rpm-ostree` or `grubby`) instead of copied files.
- `install.sh` enables what it copies (or stages kargs). `uninstall.sh`
  stops, disables, and deletes those units and files only, or removes
  that fix's kargs.
- Scripts re-exec via `distrobox-host-exec` when started inside distrobox.
  Run them on the **host**.

## License

[The Unlicense](https://unlicense.org). Free for any use.

`fingerprint/overlay/egis0570.c` and `egis0570.h` are derived from
[libfprint](https://gitlab.freedesktop.org/libfprint/libfprint) and
remain [LGPL-2.1-or-later](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).
