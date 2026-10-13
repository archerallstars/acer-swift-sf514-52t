# Agent instructions — Acer Swift SF514-52T

This repository is the **out-of-tree layer** for one laptop: Acer Swift
SF514-52T. It holds every device fix that is not yet presented or
merged upstream (kernel, alsa-ucm-conf, libfprint, firmware, and so
on). User docs: root `README.md` (chassis and index),
`scripts-audio-fix/README.md`, `scripts-fingerprint-fix/README.md`,
`scripts-igpu-fix/README.md`.
This file is what to do when changing the tree.

Fixes **layer on the base system**. The base may be a mutable root or
an ostree/immutable image. One installer must work on both.

## Layout

| Path | Role |
| --- | --- |
| `scripts-<area>-fix/` | One out-of-tree fix: install, uninstall, verify, plus that fix's payload |
| `scripts-audio-fix/` | Audio (Intel AVS + ALC255). Load-bearing rules: `scripts-audio-fix/AGENTS.md` |
| `ucm2/`, `systemd/` | Audio payload at repo root (historical). New fixes do not add sibling top-level payload dirs |
| `scripts-fingerprint-fix/` | Fingerprint (EgisTec 1c7a:0570). Load-bearing: `scripts-fingerprint-fix/AGENTS.md` |
| `fingerprint/`, `udev/` | Fingerprint overlay sources and the capture-tool udev rule |
| `scripts-igpu-fix/` | iGPU (i915 `enable_dc=0`). Load-bearing: `scripts-igpu-fix/AGENTS.md` |

Do not revive a generic `scripts/` directory. Do not put a second
subsystem's files inside `scripts-audio-fix/`.

Keep the 219654 kernel.org HTML dump, the 1213187 SUSE HTML dump, and
their `_files/` trees **out of git**. They are local research only
(see `.gitignore`).

## Layering (every fix)

- Never install by copying into `/usr`. On ostree `/usr` is immutable;
  on a mutable root we still stay off `/usr` so the same paths work.
- Writable paths: `/etc` (units, drop-ins, udev, environment.d) and
  `/var` (overlay upper dirs, scripts, state). If upstream would have
  put files in `/usr`, overlay or bind them from `/var`. The iGPU
  fix writes bootloader kernel arguments instead (`rpm-ostree kargs`
  or `grubby`).
- Each fix ships `install.sh`, `uninstall.sh`, and `verify.sh`.
  `uninstall.sh` must reverse that fix only: stop, disable, and delete
  **its** units and files. Leave other `scripts-<area>-fix` layers
  installed.
- Installers run as root **on the host**. If started inside distrobox
  they re-exec via `distrobox-host-exec`.
- Do not run a fix's `sudo ./scripts-<area>-fix/install.sh` unless the
  user asks you to apply it on this machine.
- Do not wait for an upstream PR to merge. This repo exists because
  that work is not in the base image yet.
- Do not collide with another fix's unit names, drop-in filenames, or
  `/var` directories. Prefix with `sf514-` and the area.

## New fixes

1. Create `scripts-<area>-fix/` (example: `scripts-fingerprint-fix/`).
2. Keep units, udev rules, firmware helpers, and overlay sources
   **inside that tree** (or a directory it owns). Do not add a new
   top-level `systemd/` or `ucm2/` for a second area.
3. Add a row to the Fixes table in root `README.md` and a
   `scripts-<area>-fix/README.md` for install steps and findings.
4. Add `scripts-<area>-fix/AGENTS.md` for load-bearing hardware rules
   that other areas must not break.

## Scripts

New or edited shell in this repo follows the **elementary-coder** skill
(`~/.grok/skills/elementary-coder/SKILL.md`): descriptive names, function
headers, every `if` has an `else`, config at the top, `main()` first,
local file I/O through a queue.

## Coding defaults

- Change only the `scripts-<area>-fix` (and payload) the task names.
  An audio task does not edit fingerprint or iGPU files, and the
  reverse.
- After a fix's payload or mixer/udev change, say what the user should
  run (`verify.sh` and the relevant hardware test). Do not claim the
  device is fixed without those checks.
- Upstream kernel patches are out of scope unless the user asks for
  one. Userspace layers are the default.
