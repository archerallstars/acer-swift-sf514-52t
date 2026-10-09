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
| Fingerprint | `scripts-fingerprint-fix/` | in progress |

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
| CPU / chipset | Kaby Lake, Sunrise Point-LP |

Per-fix hardware (codec, sensor, PCI ID) is documented in that fix's
section below.

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
`ALSA_CONFIG_UCM2=/var/lib/alsa/ucm2-merged` on PipeWire and
WirePlumber. On a mutable root the same overlay is used, so the
installer never writes `/usr`.

HDMI `Number` values are 1, 2, 3. Distro `codecs/hda/hdmi.conf`
programs `IEC958 Playback Switch` at `index = Number - 1`. Number 0
would yield index `-1`.

`DMIC Volume` boots at 0% (digital silence). UCM raises it to 70% when
HiFi enables; `verify.sh` does the same before raw `arecord`.

### Install

On the **host**. From distrobox the installer re-execs with
`distrobox-host-exec sudo`.

```bash
sudo ./scripts-audio-fix/install.sh
./scripts-audio-fix/verify.sh
```

Install will:

1. Create `/var/lib/alsa/ucm2-{upper,work,merged}` and copy `ucm2/`
   into the upper dir (conf.d symlinks preserved).
2. Enable the overlay mount and the headset pin unit.
3. Stop the session PipeWire stack (including sockets) so the analog
   PCM is closed.
4. Reconfig ALC255 pin `0x19` to `0x03a11130`.
5. Restart PipeWire / WirePlumber with `ALSA_CONFIG_UCM2` set.

You do not need `options snd_soc_avs obsolete_card_names=1`.

### Verify

`scripts-audio-fix/verify.sh` discovers cards from `/proc/asound/cards`.
It does not assume card numbers 1, 2, 3, and it does not treat
`wpctl status` as a pass.

After a successful install:

- Overlay readable at `/var/lib/alsa/ucm2-merged`
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
- DMIC gain: raise or lower the 70% `DMIC Volume` EnableSequence after
  listening on this chassis.

## License

[The Unlicense](https://unlicense.org). Free for any use.
