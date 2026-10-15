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

**DC=0 is a mitigation, not a cure.** The same hang recurred on
2026-10-14 with DC=0 live. Treat the karg as reducing frequency, not
guaranteeing S5. No further kargs (see *Decision: stop at DC=0*
below).

| | |
| --- | --- |
| GPU | Intel UHD Graphics 620 (Kaby Lake-R GT2) |
| PCI | `8086:5917` rev 07 |
| Driver | `i915` (DMC `kbl_dmc_ver1_04.bin`) |
| Workaround | `i915.enable_dc=0` (incomplete; hang still occurs) |
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
| Shutdown (ACPI S5) | **usually** completes promptly; can still hang (2026-10-14) |
| Restart | still works (it already did before this karg) |

`i915.enable_psr=0` alone did not stop the hang on this machine.
DC=0 also did not stop it on 2026-10-14 (see *Last shutdown*).

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
On this chassis the first shutdown after enabling DC=0 finished almost
instantly; a later hang still occurred (2026-10-14).

## Uninstall

```bash
sudo ./scripts-igpu-fix/uninstall.sh
```

Deletes `i915.enable_dc=0` only. Does not put `i915.enable_psr=0`
back. Reboot for the live kernel to drop the karg.

## Last shutdowns (this chassis)

### 2026-10-12 — hang before DC=0 was live

Host boot hung, kernel `7.2.9-200.fc44`, cmdline already had
`i915.enable_psr=0`:

| Time (local, −03) | What happened |
| --- | --- |
| 01:45:09 | `i915 *ERROR* Atomic update failure on pipe B` (vblank miss; hours before shutdown) |
| 04:05:03 | GNOME/GDM power-off; `plymouth-poweroff` starts |
| 04:05:50 | user session reaches `shutdown.target` |
| 04:05:51–04:06:03 | `ostree-finalize-staged` finishes |
| 04:06:03 | journal flush stops; unmounts start; last line `umount: /etc: target is busy` |
| — | no `Reached target poweroff`, no ACPI S5, no Oops, empty pstore |
| 16:04 | next boot (`7.2.9-201`). `last` shows 11h58m down |

### 2026-10-14 — hang **with DC=0 live**

Boot `-1`, kernel `7.2.9-201.fc44`. Cmdline ended with
`i915.enable_dc=0`; kernel log: `Setting dangerous option enable_dc -
tainting kernel`. USB BACKUP drive was plugged in.

| Time (local, −03) | What happened |
| --- | --- |
| 10:34–10:37 | apps exit (flatpak, anytype) |
| 10:37:56 | `plymouth-poweroff` starts; `dracut-shutdown` stops |
| 10:38:07 | user session `shutdown.target`; `libpod-*.scope` stop timed out (killed) |
| 10:38:08–20 | `ostree-finalize-staged` finishes (`Cleanup complete`) |
| 10:38:20 | unmounts start (`etc`, `boot-efi`, BACKUP, ostree `var`, `tmp`, `var-home`); journal dies |
| — | **no** poweroff, no Oops, empty pstore |
| User symptom | screen already **off**, fan on, USB still powered; indefinite; forced power button |
| 18:02 | next boot (`7.2.10-200.fc44`) |

Same late-unmount cut as 2026-10-12. `Atomic update failure` still
occurs with DC=0 (2 events that day) but is uncorrelated with hangs.

### Hang forensics on this host

The persistent journal **always** ends in the unmount phase (journald
var teardown). `Reached target poweroff` never appears, even after a
clean power-off. A missing poweroff line is **not** a hang proof.

Weak discriminators only:

- `systemd-reboot.service` vs `systemd-poweroff.service` in the last minute
- a stop-job timeout before journal end (seen on both hangs: `mpris-proxy`
  2026-10-12, `libpod-*.scope` 2026-10-14)
- `last` gap to next boot (utmp `shutdown` is written *before* S5)
- whether the user had to force power off

After a suspect shutdown, record:

```bash
journalctl -b -1 -o short-precise | tail -50
last -x reboot shutdown
```

Ruled out as freeze line: USB BACKUP unmount (succeeds on clean boots),
AVS audio `sound.target` spam (same on clean boots), `ostree-finalize-staged`
(always completes). Stop-job timeouts are aggravators, not the freeze.

### Platform note (Windows)

The same class of hang also occurs on **Windows on this machine** — not
on shutdown, but on **display blank**. That points at a **CPU/platform
power-management or firmware (BIOS/EC) design flaw** on this Carlsberg_KL
Kaby Lake-R chassis, not a Linux-only i915 bug. Linux `i915.enable_dc=0`
mitigates one path (display power wells on S5); it cannot fix
silicon/firmware.

## Decision: stop at DC=0 (2026-10-14)

No further kargs:

| Karg | Evidence for this hang class | Decision |
| --- | --- | --- |
| `i915.enable_dc=0` | ArchWiki names Kaby Lake Refresh; [i915#2225](https://gitlab.freedesktop.org/drm/i915/kernel/-/issues/2225); [Ubuntu 2157741](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2157741) | **Keep.** Incomplete (2026-10-14 hang) but best documented, low cost. |
| `intel_idle.max_cstate=1` | ArchWiki names KBL-R; Acer/Arch shutdown-stuck threads | **Rejected** — idle heat, fans, sustained turbo under thermal load, large battery cost. |
| `i915.enable_fbc=0` | Runtime GPU freezes / FBC errors only; **no** late-S5 reports | **Rejected** — scanout compression, not the S5 power-well path. |

Do not add either rejected karg unless the user later reverses this
decision.

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
power wells into S5. DC states matter on S5. DC=0 still does not
guarantee S5 on this chassis (2026-10-14).
