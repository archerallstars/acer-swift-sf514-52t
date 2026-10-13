# Agent instructions — iGPU fix

Load-bearing rules for `scripts-igpu-fix/`. Breaking these will
re-introduce the shutdown hang or pile extra i915 kargs onto this
Kaby Lake-R iGPU.

User-facing steps: `scripts-igpu-fix/README.md`. Repo-wide layering:
root `AGENTS.md`. Chassis index: root `README.md`.

## Do not

- Set `i915.enable_psr=0`. PSR off did not stop the last hang on
  this chassis. Kernel default is to omit the karg.
  `install.sh` deletes `i915.enable_psr=0` when it is already staged.
- Add `i915.enable_fbc=0` or `intel_idle.max_cstate=1` unless the
  user asks after DC=0 still hangs on shutdown.
- Copy anything into `/usr`. This fix only changes bootloader
  kernel arguments (`rpm-ostree kargs` or `grubby`).
- Touch `scripts-audio-fix/`, `scripts-fingerprint-fix/`, `ucm2/`,
  or fingerprint overlay sources.
- Run `sudo ./scripts-igpu-fix/install.sh` on this machine unless
  the user asks.

## Hardware

- GPU is Intel UHD Graphics 620, PCI `8086:5917` rev 07, Kaby
  Lake-R GT2, driver `i915`, DMC `kbl_dmc_ver1_04.bin`.
- Hang is random on **shutdown** (ACPI S5), not on restart. Journal
  stops during late unmount; no Oops, GPU hang, or pstore.
- `i915 *ERROR* Atomic update failure on pipe A/B` is a vblank
  miss. It is a fingerprint of the same timing class, not the
  freeze line itself.

## Install / uninstall / verify

- `install.sh` adds `i915.enable_dc=0` when that whole token is
  missing from staged kargs, and logs that it is already disabled
  when the token is present. It replaces a different
  `i915.enable_dc=` value. It deletes `i915.enable_psr=0`.
- `uninstall.sh` deletes `i915.enable_dc=0` only. It does not add
  PSR=0 back. Idempotent when DC=0 is already absent.
- Ostree: `/ostree` exists and `rpm-ostree` is on PATH. Mutable
  Fedora: `grubby --update-kernel=ALL`. Exit 1 if neither backend
  exists. No Debian `/etc/default/grub` editor.
- Token match is space-padded whole-word (`i915.enable_dc=0`), not
  a substring of another value.
- Distrobox: install/uninstall re-exec with
  `distrobox-host-exec sudo`; verify re-execs as the same user.
- `verify.sh` passes only when live `/proc/cmdline` has DC=0 and
  omits PSR=0. Staged mismatch or live-not-yet-rebooted is a fail
  (reboot required). Do not claim shutdown is fixed from verify
  alone; the user still tests a shutdown.

## Out of v1 unless the user asks

- `i915.enable_fbc=0`
- `intel_idle.max_cstate=1`
- An upstream i915 patch
