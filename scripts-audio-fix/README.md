# Audio — Intel AVS + Realtek ALC255

Back to the [chassis README](../README.md).

Restores speakers, the headphone jack, the 3.5 mm headset mic, the
internal DMIC, and HDMI / DisplayPort under `snd_soc_avs` on the
Acer Swift SF514-52T.

[Kernel bug 219654](https://bugzilla.kernel.org/show_bug.cgi?id=219654) ·
[SUSE bug 1213187](https://bugzilla.suse.com/show_bug.cgi?id=1213187) ·
[alsa-ucm-conf#871](https://github.com/alsa-project/alsa-ucm-conf/pull/871) ·
[alsa-ucm-conf#571](https://github.com/alsa-project/alsa-ucm-conf/pull/571)

[#871](https://github.com/alsa-project/alsa-ucm-conf/pull/871) is this
chassis's renamed-card UCM (AVS HD-Audio / DMIC / HDMI, including
Headset on analog `pcm0c`). This overlay does not wait for that pull
request to merge, and it does not set `obsolete_card_names=1`.

| | |
| --- | --- |
| Codec | Realtek ALC255 |
| PCI audio | `8086:9d71` subsystem `1025:1225` |
| Driver | `snd_soc_avs` (default `dsp_driver=0`) |
| Cards | `AVS PROBE`, `AVS HD-Audio`, `AVS DMIC`, `AVS HDMI` |

Under AVS the Realtek quirk never runs (boot log: `PCI SSID 1025:0000`),
so analog mic pins stay BIOS N/A. Distro UCM still matches the old
card long names, so PipeWire stays on ACP stereo-fallback. Analog
headset capture is HDA hwdep verbs plus UCM `Headset`. Live findings
for the 3.5 mm plug are in [Analog plugin mic](#analog-plugin-mic-35-mm).
Proven capture multipliers are in [Capture gain](#capture-gain).

```
scripts-audio-fix/              install, uninstall, verify, headset-mic hwdep verbs
scripts-audio-fix/wireplumber/  51/52 AVS DMIC Mult=8.0 + 53/54 analog Headset Mult=4.0
ucm2/                          AVS HD-Audio, AVS DMIC, AVS HDMI (new long names)
systemd/                       overlayfs mount, headset-mic verb unit, PipeWire drop-ins
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
`verify.sh` does the same before raw `arecord`. Extra loudness is
the WirePlumber linear filters in [Capture gain](#capture-gain).

## What works

Live on this chassis with this overlay:

| Path | Result |
| --- | --- |
| Speakers | playback works |
| 3.5 mm 2-ring headphones | playback works (HP pin stays on) |
| 3.5 mm 3-ring CTIA headset mic | capture works on **Headset Microphone** |
| Internal AVS DMIC | capture works (`Mult = 8.0`) |
| HDMI / DisplayPort | playback works |

A 2-ring analog **microphone** on this combo jack is
[not compatible](#analog-plugin-mic-35-mm).

## Install

On the **host**. From distrobox the installer re-execs with
`distrobox-host-exec sudo`.

```bash
sudo ./scripts-audio-fix/install.sh
./scripts-audio-fix/verify.sh
```

Install will:

1. Create `/var/lib/alsa/ucm2/{upper,work,merged}` and copy `ucm2/`
   into the upper dir (conf.d symlinks preserved).
2. Copy WirePlumber 51-54 fragments to
   `/etc/wireplumber/wireplumber.conf.d/` (`api.alsa.soft-mixer` and
   linear `Mult = 8.0` on DMIC and `Mult = 4.0` on analog Headset)
   and remove the session user's home copies of those same filenames
   so the gain is applied once.
3. Enable the overlay mount and the headset-mic verb unit.
4. Bounce the session PipeWire **services** (WirePlumber,
   pipewire-pulse, pipewire) with `--job-mode=replace-irreversibly`
   and `--no-warn`. Sockets stay up: stopping `pipewire.socket` in
   the same transaction as the service lets GNOME cancel the job.
5. Run ALC255 hwdep verbs: D0 on the analog path, pin `0x19`
   IN+VREF_80 after CTIA, unmute analog ADC path at +12 dB, headset
   pin default, then CTIA with pin `0x21` HP Out if Front Headphone
   Jack is on. An empty jack leaves pin `0x19` at `0x20` (VREF_HIZ).
   Never write sysfs `reconfig` (oopses on AVS). The unit stays
   running, debounces the jack, and keeps CTIA applied while a
   3-ring mic stays plugged (including across reboot).
6. Restart PipeWire / WirePlumber with `ALSA_CONFIG_UCM2` set.

You do not need `options snd_soc_avs obsolete_card_names=1`.

Unit files are copied with `install` and relabeled with `restorecon`
so Fedora Enforcing can load them. The headset unit runs the verb
script through `/usr/bin/bash` because systemd cannot execute a file
labeled `alsa_var_lib_t`. A re-run of install.sh also removes leftover
`/var/lib/alsa/ucm2-{upper,work,merged}` directories from the first
overlay path.

## Verify

`scripts-audio-fix/verify.sh` discovers cards from `/proc/asound/cards`.
It does not assume card numbers 1, 2, 3, and it does not treat
`wpctl status` as a pass. From distrobox it re-execs on the host
so `spa-acp-tool` sees the overlay.

After a successful install:

- Overlay readable at `/var/lib/alsa/ucm2/merged`
- Long names `AVS HD-Audio`, `AVS DMIC`, `AVS HDMI` (not `hdaudioB0D2`)
- Node `0x19` Pin-ctls `0x24` (IN VREF_80) when Front Headphone Jack
  is on; `0x20` (IN VREF_HIZ) when the jack is empty (unplugged UAJ
  gates MIC2 Vref)
- Node `0x21` Pin-ctls `0xc0` (HP Out; leftover mic-in turns this off)
- Analog capture PCM `pcm0c` on `AVS HD-Audio`
- UCM `Headset` device (spa-acp-tool lists it under HiFi)
- Headset unit `ExecStart` includes `--watch` (debounces Front
  Headphone Jack and keeps CTIA with HP Out)
- Installed pin script applies CTIA `0xd489` and has no mic-in path
- `spa-acp-tool -c <n> list-profiles` shows **HiFi** on HD-Audio and
  DMIC, not only `stereo-fallback`
- A non-silent WAV from
  `arecord -D hw:DMIC,0 -r 48000 -c 2 -f S16_LE -d 3`
- `/etc/wireplumber/wireplumber.conf.d/51-sf514-dmic-soft-mixer.conf`
  through `54-sf514-headset-gain.conf` present (DMIC `Mult = 8.0`,
  Headset `Mult = 4.0`)
- no home copies of those 51-54 filenames (they would stack with `/etc`)

Then, as a user: default sink is analog Speaker; plugging 2-ring
headphones switches port and plays. Analog capture is S32_LE.
HDMI/DP playback reaches the display.

- A **3-ring CTIA mic** can stay plugged all the time. Select
  **Headset Microphone** as the input. The watch unit applies CTIA
  at boot and after a plug, and re-applies it if the codec drifts.
- A **2-ring analog microphone** is not compatible (see
  [Analog plugin mic](#analog-plugin-mic-35-mm)).
- The real internal mic is AVS DMIC.

Kernel lines `Endpoint format configuration not found` during ACP probe
are expected.

If speakers vanish after UCM loads, dump `spa-acp-tool` and WirePlumber
logs (`WIREPLUMBER_DEBUG=3`) before changing mixer sequences.

`alsaucm` is optional (`alsa-utils` on Fedora). HiFi is still required
from `spa-acp-tool`.

## Uninstall

```bash
sudo ./scripts-audio-fix/uninstall.sh
```

That stops and disables the units this fix enabled, unmounts the
overlay, deletes the files it copied into `/etc` and `/var/lib/alsa`
(including the WirePlumber 51-54 gain fragments and a leftover
combo-jack udev rule), deletes matching home copies of those 51-54
filenames, reloads systemd, and restarts PipeWire. Other
`scripts-<area>-fix` layers are left alone.

## Analog plugin mic (3.5 mm)

The combo jack on this Swift takes a **CTIA TRRS (3-ring)**
headset mic. That is the plug that captured on SUSE bug 1213187
under `snd-hda-intel` (`model=1025:1330`), and it is the plug
that captures here under `snd_soc_avs`. Leave it inserted; the
watch unit keeps the codec in CTIA across reboot and session
audio restarts. In GNOME, select **Headset Microphone**.

**2-ring headphones** (TRS, playback only) use the same plugged
CTIA path. Pin `0x21` stays HP Out (`0xc0`), so those speakers
play.

A **2-ring analog microphone** on this jack is **not compatible**.
A Galaxy A25 on Android 16 also does not detect that plug as a
mic. There is no report of anyone getting this 2-ring analog
mic to work on Linux. Failed overlay attempts are listed below.

### Why the kernel quirk never runs

AVS logs PCI SSID `1025:0000`. The real subsystem is `1025:1225`.
BIOS leaves pins `0x19` / `0x1a` as `0x411111f0`, autoconfig has
empty `inputs:`, and there is no analog `Capture Switch`. Generic
HDA UCM therefore never ships a mic device. AVS topology still
exposes analog capture as `pcmC*D0c` (`HDAudio Analog`).

Writing `hwC*D0/reconfig` NULL-derefs in `snd_hda_codec_reset`
(`snd_hda_lock_devices` on a NULL card). This overlay never
writes that sysfs file. It programs the live codec through
`/dev/snd/hwC*D0` (`SNDRV_HDA_IOCTL_VERB_WRITE`).

### Widget map (ALC255)

| Node | Role on this chassis |
| --- | --- |
| `0x19` | Combo-jack headset mic. Pin default `0x03a11130`. Pin-ctls `0x24` (IN + VREF_80) with a 3-ring CTIA plug; `0x20` (IN VREF_HIZ) while the jack is empty. Amp-In max `0x7003`. Mixer index 1. |
| `0x1a` | Second analog mic pin, still BIOS N/A. Unused. Kept off. |
| `0x21` | Headphone out. OUT-only pincap; it cannot be an ADC. Stays HP Out `0xc0` while the jack is present. |
| `0x22` / `0x23` | ADC muxes. Connection index 1 is pin `0x19`. Index 2 (pin `0x1a`) stays muted. |
| `0x08` / `0x09` | Analog ADCs that feed `HDAudio Analog`. Amp-In ofs `0x17` is 0 dB (0.75 dB/step). |
| `0x20` / `0x57` | Vendor / COEFEX. Universal Audio Jack lives here. |

### Jack presence

hwdep `GET_PIN_SENSE` stays 0 with a plug in. The live control is:

```bash
amixer -c N cget iface=CARD,name='Front Headphone Jack'
```

`values=on` means inserted, `values=off` means empty. udev does
not emit `ACTION==change` for that switch, so a oneshot unit
never sees a replug. `sf514-alc255-headset.service` is
`Type=simple` with `--watch`: 0.5 s poll, three matching polls
(~1.5 s) before UAJ follows a plug or unplug.

### Universal Audio Jack (the load-bearing finding)

Working capture is **always CTIA**. Vendor coefficient `0x45`
must stay `0xd489` while the jack is present, and pin `0x21`
must stay HP Out `0xc0`.

| State | `0x45` | `0x1b` | Pin `0x21` | COEFEX `0x57/0x03` | MIC2 Vref `0x06` |
| --- | --- | --- | --- | --- | --- |
| Unplugged | `0xd089` | `0x0c0b` | HP Out `0xc0` | `0x8aa6` | `0x6104` (gated) |
| CTIA (3-ring, and 2-ring headphones) | `0xd489` | `0x0c2b` | HP Out `0xc0` | `0x8ea6` | `0x6100` (ungated) |

The kernel ALC255 type probe (`0x45=0xd089`, `0x49=0x0149`, 300 ms,
then `(0x46 & 0x0070) == 0x0070` for CTIA else OMTP) is unstable
on this chassis after insert. Live replugs of the proven 3-ring
mic returned `0x46=0x14` and `0x46=0x54` (OMTP). Capture went
silent.

Using Headphone playback on/off as a TRS vs TRRS hint also
failed. Install with the 3-ring already in applied mic-in
because Headphone was still off. Capture started only after
PipeWire turned Headphone on and CTIA was applied. Later
replugs stayed on the OMTP path.

So a present Front Headphone Jack always gets the CTIA sequence
above. Headphone playback is ignored. The type probe is not
used. `--watch` re-applies CTIA if `0x45` drifts (PipeWire
start, reboot with the mic already in).

OMTP (`0xe489`) is not used: it silenced 3-ring capture.

### Two-ring analog mic (not compatible)

This chassis quirk is `NO_HP_MIC`: pin `0x21` is OUT-only, so
the in-tree Realtek driver never selects mic-in by itself.
Public ALC255 combo-jack reports, including the 2023 HDA
write-up for this laptop, are 4-pole CTIA headset mics.

The 2-ring analog microphone that was tried here also fails
on a Galaxy A25 (Android 16 recorder). There is no known
Linux success report for that plug on this jack.

These overlay attempts did not capture voice. Several of
them also broke 2-ring **headphone** playback, so they are
not shipped:

| Attempt | Result |
| --- | --- |
| CTIA on the 2-ring plug (`0x45=0xd489`, pin `0x19` VREF_80) | left-channel sleeve hiss (about −38 dBFS RMS, ZCR ~0.53); right near silence |
| `PIN_VREFGRD` `0x22` on pin `0x19` | silent (grounds the electret) |
| `PIN_VREF50` `0x21` on pin `0x19` after `0xc489` | silent (mixers still listened to index 1) |
| Pin `0x1a` IN+VREF_80, mixer index 2 | stereo white noise (left=right, about −20 dBFS, ZCR ~0.65); PC Beep / 1Ah loopback |
| Pin `0x1a` IN+VREF_50 plus coef `0x36=0x5757` | still noise |
| Kernel `alc_headset_mode_mic_in` (`0x45=0xc489`, HP pin off) | still no voice; **turned pin `0x21` off and silenced 2-ring headphones** |
| `0x46` type probe plus a CTIA hiss check | treated 2-ring **headphones** as mic-in (same left-loud hiss signature) and applied HP-off |

### Format and volume

Analog PCM is 24-bit left-justified in `S32_LE`. Opening it as
`S16_LE` looks empty. UCM `SectionDevice."Headset"` binds
`hw:${CardId},0` with `CaptureFormat S32_LE` and `JackControl
"Front Headphone Jack"`. Proven analog gain (ADC `0x7027` plus
WirePlumber `Mult = 4.0`) is in [Capture gain](#capture-gain).

## Capture gain

These multipliers were set on this chassis with GNOME's meter.
GNOME Settings and `wpctl` stay at 1.00 on the capture nodes;
the boost is a WirePlumber builtin linear filter inside the node.
The GNOME over-amplification setting applies to speaker output.

| Source | Fragments | Match | Mult | About | Hardware on top |
| --- | --- | --- | --- | --- | --- |
| AVS DMIC (internal) | 51 soft-mixer, 52 gain | `~alsa_input.*avs_dmic.*` | `8.0` | +18 dB | UCM `DMIC Volume` 100% (ALSA max of the raw control) |
| Analog Headset (3-ring CTIA) | 53 S32LE / 24-bit, 54 gain | `~alsa_input.*avs_hdaudio.*Headset.*` | `4.0` | +12 dB | ADC unmute payload `0x7027` (~+12 dB above ofs `0x17`) |

Files live in `scripts-audio-fix/wireplumber/` and install to
`/etc/wireplumber/wireplumber.conf.d/`. Home copies of the same
filenames stack with `/etc` and apply the multiplier twice;
install and uninstall delete those home copies.

`DMIC Volume` has no 200% step. Extra DMIC loudness is the
WirePlumber `Mult`. First live DMIC boost was `4.0`. After the
3-ring analog path sounded right, DMIC `8.0` was **just about right**.
Analog `4.0` plus ADC `0x7027` is the proven 3-ring meter. To try
another value, edit `Mult` in 52 (DMIC) or 54 (Headset) and re-run
`sudo ./scripts-audio-fix/install.sh`.

## Limits (audio v1)

- Three ALSA cards, three HiFi profiles. No combined “one logical
  card” UCM (the merge blocker on PR 571).
- Generic AVS topology (`hda-generic-tplg.bin`). No custom firmware.
- Headset mic is hwdep verbs on pin `0x19`, not sysfs `reconfig`
  (that oopses on this AVS codec).
- Analog Headset Mic is a CTIA TRRS (3-ring) plug. A 2-ring analog
  microphone is not compatible. Details are in
  [Analog plugin mic](#analog-plugin-mic-35-mm). Capture multipliers
  are in [Capture gain](#capture-gain).
- Overlay + `ALSA_CONFIG_UCM2` only affects processes with that
  environment. Session audio gets it from the systemd drop-ins.
- Install still stops the session PipeWire stack so UCM and the
  verb unit apply together; the boot unit runs before `sound.target`.

## Later (audio)

- Kernel: pass the real PCI SSID `1025:1225` into the Realtek quirk
  table as `ALC255_FIXUP_ACER_HEADSET_MIC`, and make
  `snd_hda_codec_reset` safe on ASoC-bound codecs.
- Upstream: HDMI Number 1-based + `CaptureChannels 2` for this NHLT
  on [alsa-ucm-conf#871](https://github.com/alsa-project/alsa-ucm-conf/pull/871).
- DMIC and analog Headset gain: see [Capture gain](#capture-gain).
  `wpctl` stays at 1.00; the boost is inside the node.
