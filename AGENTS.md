# Agent instructions — Acer Swift SF514-52T

This repository holds **device overlays** for one laptop: Acer Swift
SF514-52T (Kaby Lake, Fedora Atomic / ostree). Read `README.md` for
user-facing install and verification. This file is what to do when
changing the tree.

## Layout

| Path | Role |
| --- | --- |
| `scripts-audio-fix/` | Audio overlay: install, uninstall, verify, headset pin reconfig |
| `ucm2/` | ALSA UCM for the renamed Intel AVS cards |
| `systemd/` | Units and drop-ins the audio installer copies to the host |
| `scripts-<area>/` | Future driver fixes. Each area gets its own script root. |

Do not revive a generic `scripts/` directory. New work belongs in
`scripts-<area>/` (for example `scripts-wifi-fix/`).

Keep the 219654 kernel.org HTML dump and its `_files/` tree **out of
git**. They are local research only (see `.gitignore`).

## Host constraints

- Target OS is Fedora Silverblue / ostree. `/usr` is immutable. Never
  install by copying into `/usr/share/alsa/ucm2` or other `/usr` paths.
- Writable install paths: `/var/lib/alsa/`, `/etc/systemd/`,
  `/etc/environment.d/`.
- `install.sh` / `uninstall.sh` must run as root **on the host**. If
  started inside distrobox they re-exec via `distrobox-host-exec`.
- Do not run `sudo ./scripts-audio-fix/install.sh` (or uninstall)
  unless the user asks you to apply it on this machine.

## Audio overlay rules

These are load-bearing. Changing them without a live check on this
chassis will break matching or HDMI IEC958:

- Match UCM as `conf.d/${CardDriver}/${CardLongName}.conf` for the
  **renamed** cards: `AVS HD-Audio`, `AVS DMIC`, `AVS HDMI`.
- Do not set `options snd_soc_avs obsolete_card_names=1`.
- Do not wait on [alsa-ucm-conf#571](https://github.com/alsa-project/alsa-ucm-conf/pull/571)
  and do not ship its unused I2S codec UCMs.
- Three ALSA cards, three HiFi profiles. No combined one-card UCM.
- No custom AVS topology firmware. Generic `hda-generic-tplg.bin` is
  enough for analog playback.
- HDMI macros: `Number` is 1-based, `Device` is 0-based. Distro
  `codecs/hda/hdmi.conf` uses `index=${eval:($__Number-1)}`. Number 0
  yields IEC958 index `-1`.
- DMIC: PCM `hw:${CardId},0`, `CaptureChannels 2`, `CaptureRate 48000`,
  mixer `DMIC`. Live `DMIC Volume` boots at 0 (silence); keep an
  EnableSequence (currently 70%) and have verify raise the same control
  before raw `arecord`.
- Headset mic: BIOS leaves pin `0x19` as `0x411111f0`. The boot unit
  writes `0x19 0x03a11130` and tries `modelname=headset-mode-no-hp-mic`,
  then `reconfig`. That must run while the analog PCM is closed
  (`Before=sound.target`; install stops PipeWire sockets first).
- `uninstall.sh` must reverse install: `systemctl stop` + `disable` both
  units, delete the unit files and drop-ins, unmount the overlay, reload
  systemd, restart the session PipeWire stack.

## Scripts

New or edited shell in this repo follows the **elementary-coder** skill
(`~/.grok/skills/elementary-coder/SKILL.md`): descriptive names, function
headers, every `if` has an `else`, config at the top, `main()` first,
local file I/O through a queue.

`verify.sh` must not treat `wpctl status` as a pass. Discover cards from
`/proc/asound/cards`. Require HiFi from `spa-acp-tool` when the overlay
is mounted.

## Coding defaults

- Change only what the task needs. Leave UCM, units, and pin values
  alone unless the task is about them.
- After UCM or mixer changes, say what the user should run
  (`verify.sh`, headphone plug test). Do not claim audio is fixed
  without those checks.
- Kernel quirk work (pass PCI SSID `1025:1225` into Realtek, or a DMI
  match) is out of v1 unless the user asks for a kernel patch.
