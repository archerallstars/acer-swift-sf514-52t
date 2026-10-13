# iGPU — Intel UHD Graphics 620 (i915)

Back to the [chassis README](../README.md).

Workaround for a **random hang on shutdown** (ACPI S5) on the Acer
Swift SF514-52T Kaby Lake-R iGPU. Restart (ACPI reset) does not hang.
The hang leaves no Oops, GPU reset, or pstore dump: systemd has already
stopped the journal.

This fix adds `i915.enable_dc=0` (disable display C-states DC5/DC6).
Panel Self Refresh stays at the **kernel default** (the karg
`i915.enable_psr=0` is not set, and install removes it if an earlier
experiment left it in place). PSR off did not stop the last hang.

| | |
| --- | --- |
| GPU | Intel UHD Graphics 620 (Kaby Lake-R GT2) |
| PCI | `8086:5917` rev 07 |
| Driver | `i915` (DMC `kbl_dmc_ver1_04.bin`) |
| Workaround | `i915.enable_dc=0` |
| PSR | kernel default (do not set `i915.enable_psr=0`) |

```
scripts-igpu-fix/install.sh    add DC=0 if missing, drop PSR=0
scripts-igpu-fix/uninstall.sh  delete DC=0 only
scripts-igpu-fix/verify.sh     live /proc/cmdline plus staged kargs
```

The payload is bootloader kernel arguments (`rpm-ostree kargs` on
ostree, `grubby` on a mutable Fedora root). Nothing is copied into
`/usr`, `/etc`, or `/var`.

## What works

Live on Fedora Silverblue 44 on this chassis with `i915.enable_dc=0`
and PSR at the kernel default:

| Step | Result |
| --- | --- |
| `verify.sh` | live and staged kargs have `i915.enable_dc=0`, omit `i915.enable_psr=0` |
| Shutdown (ACPI S5) | power-off completes promptly (almost instant) |
| Restart | still works (it already did before this karg) |

`i915.enable_psr=0` alone did not stop the hang on this machine.

## Performance

`i915.enable_dc=0` does not cut 3D, video decode, or compositor
speed. Display C-states are idle power wells, not GT clocks. Render
C-states (RC6) stay enabled.

Cost is idle power and battery: the display engine does not enter
DC5/DC6, so the package may stay out of the deepest C-states while
the panel is on. Typical extra draw is about 0.5–2 W at idle, in
the same band as other i915 power workarounds. FPS and VA-API are
unchanged.

## Install

On the **host**, as root. From distrobox the installer re-execs with
`distrobox-host-exec sudo`.

```bash
sudo ./scripts-igpu-fix/install.sh
```

Install will:

1. Use `rpm-ostree` when `/ostree` exists, otherwise `grubby`.
2. Skip adding `i915.enable_dc=0` when that token is already staged
   (log that display C-states are already disabled).
3. Replace a different `i915.enable_dc=` value when one is present.
4. Delete `i915.enable_psr=0` when that token is staged.
5. Ask for a reboot when live `/proc/cmdline` does not yet match.

Then reboot and verify:

```bash
./scripts-igpu-fix/verify.sh
```

`verify.sh` passes only when the live command line has
`i915.enable_dc=0` and does not have `i915.enable_psr=0`. If staged
kargs already match but the live kernel does not, reboot first.
On this chassis a shutdown after that reboot finished almost
instantly.

## Uninstall

```bash
sudo ./scripts-igpu-fix/uninstall.sh
```

Deletes `i915.enable_dc=0` only. Does not put `i915.enable_psr=0`
back. Reboot for the live kernel to drop the karg.

## Last shutdown (this chassis)

Host boot that hung, 2026-10-12, kernel `7.2.9-200.fc44`, cmdline
already had `i915.enable_psr=0`:

| Time (local, −03) | What happened |
| --- | --- |
| 01:45:09 | `i915 *ERROR* Atomic update failure on pipe B` (vblank miss; hours before shutdown) |
| 04:05:03 | GNOME/GDM power-off; `plymouth-poweroff` starts |
| 04:05:50 | user session reaches `shutdown.target` |
| 04:05:51–04:06:03 | `ostree-finalize-staged` finishes |
| 04:06:03 | journal flush stops; unmounts start; last line `umount: /etc: target is busy` |
| — | no `Reached target poweroff`, no ACPI S5, no Oops, empty pstore |
| 16:04 | next boot (`7.2.9-201`). `last` shows 11h58m down |

`last` recording `shutdown system down` at 04:05 does not mean ACPI
S5 succeeded: `systemd-update-utmp` runs before poweroff.

`umount: /etc: target is busy` and dirty EFI/exFAT on the next boot
also appear after successful reboots on this ostree host. They are
not a crash marker. The hang is after persistent journal is closed,
which is expected for an i915 S5 freeze.

## Why DC, not PSR

- Same CPU+GPU: [i915#2225](https://gitlab.freedesktop.org/drm/i915/kernel/-/issues/2225)
  (i5-8250U + UHD 620) — hard freeze with no kernel output;
  `i915.enable_dc=0` is the workaround.
- Same GPU family: [Ubuntu 2157741](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2157741)
  (HD 620) — `enable_psr=0` did not help; `enable_dc=0` did. Logs
  there also had `Atomic update failure on pipe A`.
- Arch Wiki [Intel graphics](https://wiki.archlinux.org/title/Intel_graphics):
  `i915.enable_dc=0` for random hangs on Kaby Lake Refresh.
- This chassis logged 23 `Atomic update failure on pipe A/B` events
  in 30 days. That is a missed vblank, not the freeze itself. It is
  the same timing class as gen9 DC bugs.

Restart vs shutdown: reboot uses ACPI reset; power-off walks display
power wells into S5. DC states matter on S5.

Do not add `i915.enable_fbc=0` or `intel_idle.max_cstate=1` unless
shutdown still hangs after this karg (the latter has a large battery
cost).
