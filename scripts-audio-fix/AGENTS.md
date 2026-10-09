# Agent instructions — audio fix

Load-bearing rules for `scripts-audio-fix/`, plus the repo-root
`ucm2/` and `systemd/` trees that this fix still owns. Changing these
without a live check on this chassis will break UCM matching or HDMI
IEC958.

User-facing steps: `README.md` (Audio section). Repo-wide layering:
root `AGENTS.md`.

## Do not

- Set `options snd_soc_avs obsolete_card_names=1`.
- Wait on [alsa-ucm-conf#571](https://github.com/alsa-project/alsa-ucm-conf/pull/571)
  or ship its unused I2S codec UCMs.
- Combine the three ALSA cards into one UCM profile.
- Add custom AVS topology firmware. Generic `hda-generic-tplg.bin` is
  enough for analog playback.
- Move `ucm2/` or `systemd/` without updating
  `scripts-audio-fix/install.sh` and `uninstall.sh` in the same change.
- Touch fingerprint or other `scripts-<area>-fix` trees from an audio
  task.

## UCM and mixer

- Match as `conf.d/${CardDriver}/${CardLongName}.conf` for the
  **renamed** cards: `AVS HD-Audio`, `AVS DMIC`, `AVS HDMI`.
- HDMI macros: `Number` is 1-based, `Device` is 0-based. Distro
  `codecs/hda/hdmi.conf` uses `index=${eval:($__Number-1)}`. Number 0
  yields IEC958 index `-1`.
- DMIC: PCM `hw:${CardId},0`, `CaptureChannels 2`, `CaptureRate 48000`,
  mixer `DMIC`. Live `DMIC Volume` boots at 0 (silence); keep an
  EnableSequence (currently 70%) and have verify raise the same control
  before raw `arecord`.

## Headset pin

BIOS leaves pin `0x19` as `0x411111f0`. The boot unit writes
`0x19 0x03a11130` and tries `modelname=headset-mode-no-hp-mic`, then
`reconfig`. That must run while the analog PCM is closed
(`Before=sound.target`; install stops PipeWire sockets first).

## Install / uninstall / verify

- Layer with overlayfs under `/var/lib/alsa/` and
  `ALSA_CONFIG_UCM2=/var/lib/alsa/ucm2-merged`. Never copy UCM into
  `/usr/share/alsa/ucm2`.
- `uninstall.sh` reverses **this** fix only: `systemctl stop` +
  `disable` the audio units, delete those unit files and drop-ins,
  unmount the UCM overlay, reload systemd, restart the session
  PipeWire stack.
- `verify.sh` must not treat `wpctl status` as a pass. Discover cards
  from `/proc/asound/cards`. Require HiFi from `spa-acp-tool` when the
  overlay is mounted.

## Out of v1 unless the user asks

Kernel quirk work: pass PCI SSID `1025:1225` into the Realtek table, or
a DMI match for Swift SF514-52T.
