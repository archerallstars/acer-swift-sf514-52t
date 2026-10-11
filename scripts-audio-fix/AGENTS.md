# Agent instructions — audio fix

Load-bearing rules for `scripts-audio-fix/`, plus the repo-root
`ucm2/` and `systemd/` trees and `scripts-audio-fix/wireplumber/`
that this fix still owns. Changing these without a live check
on this chassis will break UCM matching, HDMI IEC958, or DMIC
gain.

User-facing steps: `scripts-audio-fix/README.md`. Repo-wide layering:
root `AGENTS.md`. Chassis index: root `README.md`.

## Do not

- Set `options snd_soc_avs obsolete_card_names=1`.
- Wait on [alsa-ucm-conf#871](https://github.com/alsa-project/alsa-ucm-conf/pull/871)
  or [alsa-ucm-conf#571](https://github.com/alsa-project/alsa-ucm-conf/pull/571),
  or ship #571's unused I2S codec UCMs.
- Combine the three ALSA cards into one UCM profile.
- Add custom AVS topology firmware. Generic `hda-generic-tplg.bin` is
  enough for analog playback.
- Move `ucm2/` or `systemd/` without updating
  `scripts-audio-fix/install.sh` and `uninstall.sh` in the same change.
- Leave matching 51-54 WirePlumber fragments in the session user's
  `~/.config/wireplumber/wireplumber.conf.d/` after install. Those
  stack with `/etc` and apply each multiplier twice.
- Touch fingerprint or other `scripts-<area>-fix` trees from an audio
  task.
- Apply kernel `alc_headset_mode_mic_in` (HP pin off) or a `0x46` /
  hiss classifier that can select it. That silenced 2-ring
  headphones on this chassis.

## UCM and mixer

- Match as `conf.d/${CardDriver}/${CardLongName}.conf` for the
  **renamed** cards: `AVS HD-Audio`, `AVS DMIC`, `AVS HDMI`.
- HDMI macros: `Number` is 1-based, `Device` is 0-based. Distro
  `codecs/hda/hdmi.conf` uses `index=${eval:($__Number-1)}`. Number 0
  yields IEC958 index `-1`.
- DMIC: PCM `hw:${CardId},0`, `CaptureChannels 2`, `CaptureRate 48000`,
  mixer `DMIC`. Live `DMIC Volume` boots at 0 (silence). Keep
  EnableSequence at 100% (ALSA max of the raw integer control) and
  have verify raise the same control before raw `arecord`. Extra
  capture gain is WirePlumber `node.filter-graph.rules` with builtin
  linear `Mult = 8.0` on `~alsa_input.*avs_dmic.*`, plus
  `api.alsa.soft-mixer = true`. Those fragments live in
  `scripts-audio-fix/wireplumber/` and install under
  `/etc/wireplumber/wireplumber.conf.d/` as 51 and 52. Delete the
  session user's home copies of the same names on install.
  `wpctl` remaining at 1.00 on this source is expected.

## Headset mic (AVS)

BIOS leaves analog mic pins `0x19`/`0x1a` as `0x411111f0`. Autoconfig
logs empty `inputs:` and the mixer has no `Capture Switch`. Generic
HDA UCM therefore never includes `HiFi-mic.conf`. AVS topology still
exposes analog capture as `pcmC*D0c` (`HDAudio Analog`).

**Never write `hwC*D0/reconfig`.** On this ASoC-bound ALC255 that
sysfs store NULL-derefs in `snd_hda_codec_reset` (`snd_hda_lock_devices`
on a NULL card). SUSE 1213187 `model=1025:1330` applied on
`snd-hda-intel`; it does not retask the parser here.

The boot unit programs the live codec through `/dev/snd/hwC*D0`
(HDA hwdep, `CAP_SYS_RAWIO`): D0 on pin `0x19`, mixers `0x22`/`0x23`,
and ADCs `0x08`/`0x09`; `SET_CONFIG_DEFAULT` `0x03a11130` on `0x19`;
pin `0x19` `SET_PIN_WIDGET_CONTROL 0x24` (IN + VREF_80) and Amp-In
boost; unmute ADC mux index 1 on `0x22`/`0x23` and mute index 2;
unmute ADCs `0x08`/`0x09`; `alc255_set_default_jack_type`
(`0x45=0xd089`). A present Front Headphone Jack always gets CTIA
(`0x45=0xd489`) with pin `0x19` IN+VREF_80 (`0x24`), pin `0x21`
HP Out (`0xc0`), and pin `0x1a` off. Unplugged UAJ gates MIC2
Vref, so pin `0x19` then reads `0x20` (IN VREF_HIZ). Require
`0x24` only after CTIA; do not `exit 1` on `0x20` while the
jack is empty. That is the Acer 1213187 headset-mic mode, and
it keeps 2-ring headphone playback working. Do not apply kernel
`alc_headset_mode_mic_in` (`0x45=0xc489`, HP pin off): it captured
only noise on a 2-ring analog mic and silenced 2-ring headphones.
Immediate CTIA-vs-OMTP probes on this AVS codec return OMTP
after a replug and kill capture. Headphone playback
on/off is ignored so PipeWire mixer changes cannot flip UAJ.
Pin `0x21` is OUT-only. hwdep GET_PIN_SENSE stays 0; udev does
not emit change events for the Front Headphone input switch.
The unit is `Type=simple --watch`: it debounces that kcontrol
and re-applies CTIA when coef `0x45` drifts, so a 3-ring mic
left plugged survives reboot. Analog ADCs unmute at payload
`0x7027` (about +12 dB). WirePlumber 53/54 apply `S32LE` /
`alsa.resolution_bits = 24` and linear `Mult = 4.0` on
`~alsa_input.*avs_hdaudio.*Headset.*`. UCM
`SectionDevice."Headset"` binds `hw:${CardId},0` with `JackControl
"Front Headphone Jack"` and `CaptureFormat S32_LE`.

Do not retask pin `0x21` as an ADC (no IN pincap). Analog headset
capture is a CTIA TRRS (3-ring) mic on Headset Microphone. A
2-ring analog microphone on this combo jack is not compatible.
Real internal capture is AVS DMIC.

The boot unit runs `/usr/bin/bash` with the pin script as
its argument. The script lives under `/var/lib/alsa/`
(`alsa_var_lib_t`). systemd (`init_t`) is denied execute on
that type (status 203/EXEC). bash is `shell_exec_t` and
reads the script as data. Python 3 issues the hwdep ioctl.

## Install / uninstall / verify

- Layer with overlayfs under `/var/lib/alsa/ucm2/{upper,work,merged}`
  and `ALSA_CONFIG_UCM2=/var/lib/alsa/ucm2/merged`. Never copy UCM into
  `/usr/share/alsa/ucm2`. The merged path must systemd-escape to
  `var-lib-alsa-ucm2-merged.mount` (no hyphen in the last component).
  Stop the overlay mount before deleting or recopying upper trees;
  overlayfs otherwise keeps empty nlink-0 dirs in the merge.
- Relabel installed unit files with `restorecon`. `cp -a` from the
  user's home leaves `user_home_t`, and systemd cannot read that.
- Do not `systemctl --user stop pipewire.socket` in the same
  transaction as `pipewire.service`. The service `Requires=` the
  socket; gnome-shell reconnect then cancels the socket job
  (`Job for pipewire.socket canceled`) and install aborts after
  the overlay is already in place. Stop WirePlumber / pipewire-pulse
  / pipewire **services** with `--job-mode=replace-irreversibly`
  and `--no-warn` (sockets stay up, so systemd would otherwise
  print `triggering units are still active: pipewire.socket`),
  then start sockets and restart the services so
  `ALSA_CONFIG_UCM2` drop-ins apply. A canceled stop must not
  `exit 1`.
- Install WirePlumber 51-54 under `/etc/wireplumber/wireplumber.conf.d/`
  and delete the session user's home copies of those filenames.
- `uninstall.sh` reverses **this** fix only: `systemctl stop` +
  `disable` the audio units, delete those unit files, drop-ins, and
  WirePlumber 51-54 fragments under `/etc` and matching home copies
  of those filenames, unmount the UCM overlay, reload systemd,
  restart the session PipeWire stack.
- `verify.sh` must not treat `wpctl status` as a pass. Discover cards
  from `/proc/asound/cards`. From distrobox it re-execs on the host
  so `spa-acp-tool` uses `/var/lib/alsa/ucm2/merged`. Require HiFi
  from `spa-acp-tool` when the overlay is mounted; retry a few times
  because a just-restarted PipeWire stack can list only off+pro-audio
  for a moment. Close GNOME Settings capture meters if HD-Audio or
  DMIC stay on pro-audio. Require live pin `0x19` Pin-ctls `0x24`
  (VREF_80) when Front Headphone Jack is on. An empty jack is
  `0x20` (IN VREF_HIZ) because unplugged UAJ gates MIC2 Vref; that
  is a pass. Pin `0x21` Pin-ctls `0xc0` (HP Out) is required either
  way. Also require analog capture PCM `pcm0c`, UCM `Headset`, the
  headset unit `--watch` poll, and the installed pin script to set
  CTIA `0xd489` plus HP Out `0xc0` with no
  `codec_apply_alc255_mic_in_headset_mode`. Do not require analog
  `Capture Switch` (it never appears under AVS on this BIOS). Require
  the 51-54 fragments under `/etc/wireplumber/wireplumber.conf.d/`
  (DMIC `Mult = 8.0`, Headset `Mult = 4.0`). A leftover home copy of
  those filenames is a fail. `wpctl` volume 1.00 on the DMIC is
  expected. Analog headset capture still needs a plugged jack and
  Headset Microphone selected. A 3-ring CTIA mic can stay plugged;
  verify does not treat an empty jack as a fail.

## Out of v1 unless the user asks

Kernel quirk work: pass the real PCI SSID `1025:1225` into the Realtek
table as `ALC255_FIXUP_ACER_HEADSET_MIC` (AVS currently logs
`1025:0000`), and make `snd_hda_codec_reset` safe on ASoC-bound
codecs so sysfs reconfig can work.
