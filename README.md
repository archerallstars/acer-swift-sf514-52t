# Acer Swift SF514-52T

Out-of-tree device fixes for this Kaby Lake laptop. Anything that is
not yet in the upstream kernel or related projects lives here, as a
**layer on the base system** — whether that base is a mutable root or
an ostree/immutable image.

Each fix is a `scripts-<area>-fix/` tree with its own install,
uninstall, and verify. Installers write `/etc` and `/var` (systemd
units, drop-ins, overlayfs). They do not require writing `/usr`, so
the same layer works on Fedora Atomic and on a mutable distro.

## Fixes

| Area | Tree | Status |
| --- | --- | --- |
| Audio (Intel AVS + Realtek ALC255) | [`scripts-audio-fix/`](scripts-audio-fix/) | shipped |
| Fingerprint (EgisTec 1c7a:0570) | [`scripts-fingerprint-fix/`](scripts-fingerprint-fix/) | shipped |

New work goes in a new `scripts-<area>-fix/` directory. Do not dump
unrelated fixes into `scripts-audio-fix/`.

## How a fix layers

- **Mutable or immutable.** Prefer `/etc` and `/var`. If the payload
  normally lives under `/usr` (ALSA UCM, firmware, hwdb), overlay or
  bind it from `/var` instead of copying into `/usr`.
- **Own units.** `install.sh` enables what it copies.
  `uninstall.sh` stops, disables, and deletes those units and files.
- **Host, not the container.** Scripts re-exec via
  `distrobox-host-exec` when started inside distrobox.

## Hardware

| | |
| --- | --- |
| Machine | Acer Swift SF514-52T |
| CPU | Intel Core i5-8250U (Kaby Lake-U) |
| Audio | Realtek ALC255 (`8086:9d71` subsystem `1025:1225`) |
| Fingerprint | EgisTec `1c7a:0570` press pad (below the arrow keys) |

Driver quirks, mixer names, and USB serial are in each fix's section
below.

## Audio (`scripts-audio-fix`)

Restores speakers, the headphone jack, the 3.5 mm headset mic, the
internal DMIC, and HDMI / DisplayPort under `snd_soc_avs`.

[Kernel bug 219654](https://bugzilla.kernel.org/show_bug.cgi?id=219654) ·
[alsa-ucm-conf#571](https://github.com/alsa-project/alsa-ucm-conf/pull/571)

This overlay does not wait for that UCM pull request to merge, and it
does not set `obsolete_card_names=1`.

| | |
| --- | --- |
| Codec | Realtek ALC255 |
| PCI audio | `8086:9d71` subsystem `1025:1225` |
| Driver | `snd_soc_avs` (default `dsp_driver=0`) |
| Cards | `AVS PROBE`, `AVS HD-Audio`, `AVS DMIC`, `AVS HDMI` |

Under AVS the Realtek quirk `ALC255_FIXUP_ACER_HEADSET_DMIC` never
runs (boot log: `PCI SSID 1025:0000`), so pin `0x19` stays BIOS-disabled.
Distro UCM still matches the old card long names, so PipeWire stays on
ACP stereo-fallback.

```
scripts-audio-fix/     install, uninstall, verify, headset pin reconfig
ucm2/                  AVS HD-Audio, AVS DMIC, AVS HDMI (new long names)
systemd/               overlayfs mount, pin unit, PipeWire drop-ins
```

(`ucm2/` and `systemd/` at the repo root belong to this audio fix.
Later fixes keep their payload inside their own `scripts-<area>-fix/`
tree.)

On an immutable `/usr`, install merges this UCM over
`/usr/share/alsa/ucm2` with overlayfs under `/var/lib/alsa/` and sets
`ALSA_CONFIG_UCM2=/var/lib/alsa/ucm2/merged` on PipeWire and
WirePlumber. On a mutable root the same overlay is used, so the
installer never writes `/usr`.

HDMI `Number` values are 1, 2, 3. Distro `codecs/hda/hdmi.conf`
programs `IEC958 Playback Switch` at `index = Number - 1`. Number 0
would yield index `-1`.

`DMIC Volume` boots at 0% (digital silence). UCM raises it to 100%
(the ALSA max of that raw integer control) when HiFi enables;
`verify.sh` does the same before raw `arecord`. Session volume above
100% is PipeWire amplification in GNOME.

### Install

On the **host**. From distrobox the installer re-execs with
`distrobox-host-exec sudo`.

```bash
sudo ./scripts-audio-fix/install.sh
./scripts-audio-fix/verify.sh
```

Install will:

1. Create `/var/lib/alsa/ucm2/{upper,work,merged}` and copy `ucm2/`
   into the upper dir (conf.d symlinks preserved).
2. Enable the overlay mount and the headset pin unit.
3. Stop the session PipeWire stack (including sockets) so the analog
   PCM is closed.
4. Reconfig ALC255 pin `0x19` to `0x03a11130`.
5. Restart PipeWire / WirePlumber with `ALSA_CONFIG_UCM2` set.

You do not need `options snd_soc_avs obsolete_card_names=1`.

Unit files are copied with `install` and relabeled with `restorecon`
so Fedora Enforcing can load them. The headset unit runs the pin
script through `/usr/bin/bash` because systemd cannot execute a file
labeled `alsa_var_lib_t`. A re-run of install.sh also removes leftover
`/var/lib/alsa/ucm2-{upper,work,merged}` directories from the first
overlay path.

### Verify

`scripts-audio-fix/verify.sh` discovers cards from `/proc/asound/cards`.
It does not assume card numbers 1, 2, 3, and it does not treat
`wpctl status` as a pass.

After a successful install:

- Overlay readable at `/var/lib/alsa/ucm2/merged`
- Long names `AVS HD-Audio`, `AVS DMIC`, `AVS HDMI` (not `hdaudioB0D2`)
- Pin `0x19` = `0x03a11130` on the ALC255 codec sysfs node
- `spa-acp-tool -c <n> list-profiles` shows **HiFi** on HD-Audio and
  DMIC, not only `stereo-fallback`
- A non-silent WAV from
  `arecord -D hw:DMIC,0 -r 48000 -c 2 -f S16_LE -d 3`

Then, as a user: default sink is analog Speaker; plugging headphones
switches port; a CTIA headset exposes analog Mic; HDMI/DP playback
reaches the display.

Kernel lines `Endpoint format configuration not found` during ACP probe
are expected.

If speakers vanish after UCM loads, dump `spa-acp-tool` and WirePlumber
logs (`WIREPLUMBER_DEBUG=3`) before changing mixer sequences.

`alsaucm` is optional (`alsa-utils` on Fedora). HiFi is still required
from `spa-acp-tool`.

### Uninstall

```bash
sudo ./scripts-audio-fix/uninstall.sh
```

That stops and disables the units this fix enabled, unmounts the
overlay, deletes the files it copied into `/etc` and `/var/lib/alsa`,
reloads systemd, and restarts PipeWire. Other `scripts-<area>-fix`
layers are left alone.

### Limits (audio v1)

- Three ALSA cards, three HiFi profiles. No combined “one logical
  card” UCM (the merge blocker on PR 571).
- Generic AVS topology (`hda-generic-tplg.bin`). No custom firmware.
- Headset mic is a userspace reconfig. If
  `headset-mode-no-hp-mic` breaks headphone playback, drop the
  `modelname` write in `scripts-audio-fix/apply-headset-pins.sh` and
  keep the pin default.
- Overlay + `ALSA_CONFIG_UCM2` only affects processes with that
  environment. Session audio gets it from the systemd drop-ins.
- `reconfig` fails if anything still holds `hw:HDAudio`. Install
  stops PipeWire first; the boot unit runs before `sound.target`.

### Later (audio)

- Kernel: pass PCI SSID `1025:1225` into the Realtek quirk table, or
  add a DMI match for Swift SF514-52T.
- Upstream: HDMI Number 1-based + `CaptureChannels 2` for this NHLT
  on PR 571.
- DMIC gain: the EnableSequence is 100% of the raw ALSA control.
  Further loudness is PipeWire volume above 100% in GNOME.

## Fingerprint (EgisTec 1c7a:0570)

The pad below the arrow keys is USB `1c7a:0570` (serial `W70D612F`). Fedora
already ships libfprint's `egis0570` driver, so `fprintd-list` sees the
device. That driver treats a **press** pad as a **swipe** and matches
tiny 114×57 frames with NBIS/BOZORTH3. Enroll never becomes usable
login. See [`fingerprint/diagnosis.md`](fingerprint/diagnosis.md).

This overlay is a press-mode libfprint driver plus a clean-room
Gabor/NCC matcher, loaded beside the ostree `libfprint` through
`LD_LIBRARY_PATH`. It does not `rpm-ostree override` anything and it
does not touch the ALSA/UCM tree.

| | |
| --- | --- |
| Sensor | EgisTec Touch Fingerprint Sensor (LighTuning) |
| USB | `1c7a:0570` serial `W70D612F` bcdDevice 10.41 |
| Type | Press pad below the arrow keys, five 114×57 frames per capture |
| Stock driver | Fedora `egis0570` (swipe + NBIS) |

```
scripts-fingerprint-fix/      install, uninstall, verify
fingerprint/overlay/          press-mode egis0570 + ridge matcher
fingerprint/capture/          libusb dump tool (PGM + mean/stddev)
fingerprint/build-overlay.sh  builds libfprint 1.94.10 into fingerprint/dist/
systemd/sf514-egis0570.conf   fprintd.service drop-in
udev/70-sf514-egis0570.rules  seat uaccess for the capture tool
```

### Install

Build in distrobox (meson, ninja, gcc, libusb, glib, gusb), then
install on the Silverblue **host**. Scripts re-exec via
`distrobox-host-exec sudo` when started inside a container.

```bash
make -C fingerprint/capture
./fingerprint/build-overlay.sh
sudo ./scripts-fingerprint-fix/install.sh
./scripts-fingerprint-fix/verify.sh
```

Install will:

1. Copy `libfprint-2.so.2` to `/var/usrlocal/lib64/` (`/usr/local/lib64`).
2. Copy the capture tool to `/var/usrlocal/bin/sf514-egis0570-capture`.
3. Install `systemd/sf514-egis0570.conf` as
   `/etc/systemd/system/fprintd.service.d/sf514-egis0570.conf`
   (`LD_LIBRARY_PATH=/var/usrlocal/lib64`).
4. Install `udev/70-sf514-egis0570.rules` so the seat user can run the
   capture tool (fprintd itself runs as root).
5. Add a persistent SELinux `lib_t` fcontext on the overlay `.so` and
   `restorecon`.
6. `systemctl daemon-reload` and restart `fprintd.service`.

`authselect` `with-fingerprint` stays as it is. PAM still talks to
fprintd over D-Bus.

Then enroll:

```bash
fprintd-enroll
fprintd-verify
```

Press firmly, centred, and hold about a second. Lift between the eight
enroll stages. Cover a few positions (centre, slight shifts) rather
than one identical press.

Stock swipe templates cannot be reused. If you had prints from the
Fedora driver, delete them with `fprintd-delete` and enroll again.

### Verify

`scripts-fingerprint-fix/verify.sh` checks plumbing with no finger on
the pad:

- USB `1c7a:0570` present
- Overlay `.so` at `/var/usrlocal/lib64/libfprint-2.so.2`
- fprintd drop-in present (`LD_LIBRARY_PATH=/var/usrlocal/lib64`)
- SELinux type `lib_t` on the overlay `.so`
- `fprintd-list` names Egis 0570
- `/proc/$(pidof fprintd)/maps` shows the overlay library

`./scripts-fingerprint-fix/verify.sh --live` also enrolls (if this
user has no prints) and runs `fprintd-verify` once.

### Uninstall

```bash
sudo ./scripts-fingerprint-fix/uninstall.sh
```

That removes the drop-in, the overlay `.so` and soname links, the
capture binary, and the SELinux fcontext this repo added, then restarts
fprintd onto ostree `/usr/lib64/libfprint-2.so.2`. It does **not**
delete `/var/lib/fprint/`. Use `fprintd-delete` if you want those
prints gone.

### Persistence across Silverblue rebases

| Event | What happens |
| --- | --- |
| `rpm-ostree upgrade` | Ostree `/usr/lib64/libfprint-2.so.2` may change. Overlay `.so` and `/etc` drop-in stay. fprintd still loads the overlay. |
| Layered-package churn | Unrelated. This overlay never adds `libfprint` to `LayeredPackages`. |
| libfprint ABI jump on a Fedora rebase | Overlay `.so` may be too old. Re-run `fingerprint/build-overlay.sh`, then `sudo ./scripts-fingerprint-fix/install.sh`. |

### Capture dumps (no overlay required)

Only one process can claim the pad. Stop fprintd first.

```bash
sudo systemctl stop fprintd.service
./fingerprint/capture/sf514-egis0570-capture --output-dir fingerprint/captures --label empty
./fingerprint/capture/sf514-egis0570-capture --output-dir fingerprint/captures --label finger
```

Protocol notes: [`fingerprint/protocol.md`](fingerprint/protocol.md).

Matcher self-test (no pad required):

```bash
make -C fingerprint/overlay self-test
```

Score two captured PGM frames with the same matcher the overlay uses:

```bash
./fingerprint/overlay/sf514-egis0570-ridge-eval fingerprint/captures/finger-000-frame0.pgm fingerprint/captures/finger-000-frame1.pgm
```

### Limits (fingerprint v1)

- Matcher threshold in `fingerprint/overlay/egis0570.h`
  (`EGIS0570_MATCH_THRESHOLD`) is a starting point. A too-low value
  accepts the wrong finger.
- 114×57 is a small sensor. Enroll with coverage. Adjacent fingers on
  the same hand are the hard case.
- fprintd `ProtectSystem=strict` plus SELinux `fprintd_t` require the
  drop-in and `lib_t` on the overlay `.so`. A raw copy into
  `/var/usrlocal` without `restorecon` will fail to mmap.

## License

[The Unlicense](https://unlicense.org). Free for any use.

`fingerprint/overlay/egis0570.c` and `egis0570.h` are derived from
[libfprint](https://gitlab.freedesktop.org/libfprint/libfprint) and
remain [LGPL-2.1-or-later](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).
