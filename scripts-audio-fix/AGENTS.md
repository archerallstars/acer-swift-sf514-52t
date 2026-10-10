# Agent instructions — audio fix

Load-bearing rules for `scripts-audio-fix/`, plus the repo-root
`ucm2/` and `systemd/` trees and `scripts-audio-fix/wireplumber/`
that this fix still owns. Changing these without a live check
on this chassis will break UCM matching, HDMI IEC958, or DMIC
gain.

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
- Leave matching 51/52 WirePlumber fragments in the session user's
  `~/.config/wireplumber/wireplumber.conf.d/` after install. Those
  stack with `/etc` and apply `Mult = 4.0` twice.
- Touch fingerprint or other `scripts-<area>-fix` trees from an audio
  task.

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
  linear `Mult = 4.0` on `~alsa_input.*avs_dmic.*`, plus
  `api.alsa.soft-mixer = true`. Those fragments live in
  `scripts-audio-fix/wireplumber/` and install under
  `/etc/wireplumber/wireplumber.conf.d/` as 51 and 52. Delete the
  session user's home copies of the same names on install.
  `wpctl` remaining at 1.00 on this source is expected.

## Headset pin

BIOS leaves pin `0x19` as `0x411111f0`. The boot unit writes
`0x19 0x03a11130` and tries `modelname=headset-mode-no-hp-mic`, then
`reconfig`. That must run while the analog PCM is closed
(`Before=sound.target`; install stops PipeWire sockets first).

The boot unit runs `/usr/bin/bash` with the pin script as
its argument. The script lives under `/var/lib/alsa/`
(`alsa_var_lib_t`). systemd (`init_t`) is denied execute on
that type (status 203/EXEC). bash is `shell_exec_t` and
reads the script as data.

Writing `reconfig` tears down `hwC*D0`; the writer is often
SIGKILL'd after the pin is stored. The script runs that write
in a subshell and the unit sets `SuccessExitStatus=SIGKILL`.

## Install / uninstall / verify

- Layer with overlayfs under `/var/lib/alsa/ucm2/{upper,work,merged}`
  and `ALSA_CONFIG_UCM2=/var/lib/alsa/ucm2/merged`. Never copy UCM into
  `/usr/share/alsa/ucm2`. The merged path must systemd-escape to
  `var-lib-alsa-ucm2-merged.mount` (no hyphen in the last component).
  Stop the overlay mount before deleting or recopying upper trees;
  overlayfs otherwise keeps empty nlink-0 dirs in the merge.
- Relabel installed unit files with `restorecon`. `cp -a` from the
  user's home leaves `user_home_t`, and systemd cannot read that.
- Install WirePlumber 51/52 under `/etc/wireplumber/wireplumber.conf.d/`
  and delete the session user's home copies of those filenames.
- `uninstall.sh` reverses **this** fix only: `systemctl stop` +
  `disable` the audio units, delete those unit files, drop-ins, and
  WirePlumber 51/52 fragments under `/etc` and matching home copies
  of those filenames, unmount the UCM overlay, reload systemd,
  restart the session PipeWire stack.
- `verify.sh` must not treat `wpctl status` as a pass. Discover cards
  from `/proc/asound/cards`. Require HiFi from `spa-acp-tool` when the
  overlay is mounted. Require the 51/52 fragments under
  `/etc/wireplumber/wireplumber.conf.d/` (`Mult = 4.0`). A leftover
  home copy of those filenames is a fail. `wpctl` volume 1.00 on the
  DMIC is expected.

## Out of v1 unless the user asks

Kernel quirk work: pass PCI SSID `1025:1225` into the Realtek table, or
a DMI match for Swift SF514-52T.
