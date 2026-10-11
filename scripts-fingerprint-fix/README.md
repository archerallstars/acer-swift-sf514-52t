# Fingerprint — EgisTec 1c7a:0570

Back to the [chassis README](../README.md).

Press-mode overlay for the pad below the arrow keys on the Acer Swift
SF514-52T. Fedora already ships libfprint's `egis0570`, so
`fprintd-list` sees the device. That in-tree driver treats a **press**
pad as a **swipe** and never becomes usable login.

This overlay is a press-mode libfprint driver plus a clean-room ridge
NCC matcher. fprintd loads it beside the distro `libfprint` through
`LD_LIBRARY_PATH`. It does not replace `/usr` and it does not touch
the ALSA/UCM tree.

Deeper research notes: [`fingerprint/diagnosis.md`](../fingerprint/diagnosis.md),
[`fingerprint/protocol.md`](../fingerprint/protocol.md).

| | |
| --- | --- |
| Sensor | EgisTec Touch Fingerprint Sensor (LighTuning) |
| USB | `1c7a:0570` serial `W70D612F` (USB string `070D612F`) bcdDevice 10.41 |
| Type | Landscape press pad below the arrow keys (finger sits portrait), five 114×57 frames per capture |
| Stock driver | Fedora `egis0570` (swipe + NBIS) |
| Overlay matcher | z-score NCC, threshold 0.48 |
| Quality bar | Official Windows driver on this chassis is about 3–4 accepts out of 5 |

```
scripts-fingerprint-fix/      install, uninstall, verify
fingerprint/overlay/          press-mode egis0570 + ridge matcher
fingerprint/capture/          libusb dump tool (PGM + mean/stddev)
fingerprint/build-overlay.sh  builds libfprint 1.94.10 into fingerprint/dist/
systemd/sf514-egis0570.conf   fprintd.service drop-in
udev/70-sf514-egis0570.rules  seat uaccess for the capture tool
```

## What works

Live on Fedora Silverblue 44 on this chassis:

| Step | Result |
| --- | --- |
| Enumerate | `fprintd-list` names Egis 0570, `scan-type` is `press` |
| Enroll | three stages (nail / centre / joint), gallery `aay` × 9 |
| Verify | same-finger hit rate matches Windows on this pad (about 3–4 out of 5) |
| Login | PAM is left to the distro (`authselect enable-feature with-fingerprint`) |

## Distro support

The installer is the same on a mutable root and on ostree: it only
writes `/var/usrlocal` and `/etc`. It needs **systemd**, **fprintd**,
and a **libfprint 2** ABI that matches the overlay you built.

Build `fingerprint/build-overlay.sh` on the same distro (or a
container of that distro) that will run fprintd. An `.so` built on
openSUSE may not load on Debian.

| Host | What the installer does |
| --- | --- |
| Fedora Atomic / Silverblue | `/var/usrlocal` is `/usr/local`. SELinux `lib_t` via restorecon. |
| Fedora Workstation (mutable) | Creates `/var/usrlocal`. SELinux fcontext on that path if policy does not already map it. |
| Debian / Ubuntu / Arch | No SELinux. AppArmor snippet only if a fprintd profile exists. |

PAM is left to the distro (`authselect enable-feature with-fingerprint`
or `pam-auth-update --enable fprintd`). This overlay does not edit
`/etc/pam.d`.

## Install

Build (meson, ninja, gcc, libusb, glib, gusb), then install as root
on the **host**. Scripts re-exec via `distrobox-host-exec sudo` when
started inside a container.

```bash
make -C fingerprint/capture
./fingerprint/build-overlay.sh
sudo ./scripts-fingerprint-fix/install.sh
./scripts-fingerprint-fix/verify.sh
```

Install will:

1. Copy `libfprint-2.so.2` to `/var/usrlocal/lib64/`.
2. Copy the capture tool to `/var/usrlocal/bin/sf514-egis0570-capture`.
3. Install `systemd/sf514-egis0570.conf` as
   `/etc/systemd/system/fprintd.service.d/sf514-egis0570.conf`
   (`LD_LIBRARY_PATH=/var/usrlocal/lib64`).
4. Install `udev/70-sf514-egis0570.rules` so the seat user can run the
   capture tool (fprintd itself runs as root).
5. Label the overlay `.so` (`lib_t`) and the fprintd drop-in
   (`systemd_unit_file_t`) when SELinux is on, or add an AppArmor
   `mr` rule. Skip those steps on hosts without them.
6. `systemctl daemon-reload` before udev, then stop `fprintd.service`,
   reload until the drop-in is listed, and start it.

A re-run also deletes a leftover `/var/usrlocal/bin/fprintd-enroll`
wrapper if one is present, so PATH is the distro CLI.

## Enroll

If a print is already stored from an earlier overlay, delete it first
so the three fingertip strips are captured with the current driver:

```bash
fprintd-delete "$USER"
fprintd-enroll
fprintd-verify
```

Start with the pad empty (the first capture is the empty background).
The pad is a landscape strip (114×57 under the arrow keys); a finger
sits portrait on it, so each press is only one height of the fingertip.
That is how this sensor is used, including on the official Windows
driver.

Three enroll presses, **different heights** on the same finger:

1. Toward the nail
2. Centre of the pad
3. Toward the joint

Hold about a second, then lift. If fprintd says the finger is not
centered, the new strip looks like one you already stored — slide
up or down and try that stage again. Verify matches the live press
against any stored strip.

`fprintd-delete` needs a username (`fprintd-delete "$USER"`). A bare
invocation only prints usage.

## Verify

`scripts-fingerprint-fix/verify.sh` checks plumbing with no finger on
the pad:

- USB `1c7a:0570` present
- Overlay `.so` at `/var/usrlocal/lib64/libfprint-2.so.2`
- fprintd drop-in present (`LD_LIBRARY_PATH=/var/usrlocal/lib64`)
- SELinux type `lib_t` on the overlay `.so`
- `fprintd-list` names Egis 0570
- Overlay library: `/proc/$(pidof fprintd)/maps` when readable,
  otherwise the merged fprintd unit lists
  `LD_LIBRARY_PATH=/var/usrlocal/lib64`

`./scripts-fingerprint-fix/verify.sh --live` also enrolls (if this
user has no prints) and runs `fprintd-verify` once.

Watch the daemon with `journalctl -u fprintd.service -f`. Overlay
verify lines look like:

```
verify score=0.5453 threshold=0.48 gallery_type=aay gallery_frames=9 probe_mean=48.41 probe_stddev=18.57 probe_skin=0.99 hold_frames=3
```

A pass is `score` ≥ `threshold`. `scan-type` `press` plus that
`LD_LIBRARY_PATH` means the overlay is loaded. Stock and overlay both
advertise the same Egis 0570 name, so `fprintd-list` naming the device
is not enough.

## Uninstall

```bash
sudo ./scripts-fingerprint-fix/uninstall.sh
```

That removes the drop-in, the overlay `.so` and soname links, the
capture binary, and any SELinux fcontext or AppArmor snippet this repo
added, then restarts fprintd onto the distro `libfprint-2.so.2`. It
does **not** delete `/var/lib/fprint/`. Use `fprintd-delete "$USER"` if you
want those prints gone. See [Security](#security).

## Persistence across upgrades

| Event | What happens |
| --- | --- |
| `rpm-ostree upgrade` | Ostree `/usr/lib64/libfprint-2.so.2` may change. Overlay `.so` and `/etc` drop-in stay. fprintd still loads the overlay. |
| `dnf` / `apt` / `pacman` upgrade | Distro `libfprint` in `/usr` may change. Overlay in `/var` stays. Rebuild if the ABI jumps. |
| Layered-package churn | Unrelated. This overlay never adds `libfprint` to `LayeredPackages`. |
| libfprint ABI jump | Overlay `.so` may be too old. Re-run `fingerprint/build-overlay.sh` on that distro, then `sudo ./scripts-fingerprint-fix/install.sh`. |

## Security

This overlay sits on the login path. Enrolled templates and optional
diagnostic dumps are stored in the clear: distro fprintd files under
`/var/lib/fprint/`, plus local PGM dumps from the capture tool.

### Enrolled prints (`/var/lib/fprint/`)

Enroll writes libfprint `FPI_PRINT_RAW` templates: up to nine 114×57
frames (`aay` × 9, 6498 bytes each) as the driver's `fpi-data`. Those
are **literal ridge pixels**, wrapped in libfprint's `FP3` serialize
format (`fp_print_serialize`). They are reconstructable as PGM. Stock
swipe `egis0570` stores NBIS minutiae in the same tree; this overlay
stores images because the NCC matcher needs the pixels.

fprintd (root) writes them under `/var/lib/fprint/<user>/…` with
directory mode 0700 (`DIR_PERMS` in fprintd `file_storage.c`, systemd
`StateDirectoryMode=0700`). File contents are unencrypted
(`g_file_set_contents`). Protection is the host:

- root-owned 0700 tree (other users cannot traverse it)
- fprintd as root, D-Bus / polkit for enroll and verify
- SELinux `fprintd_t` on Fedora; AppArmor where a fprintd profile exists
- systemd sandbox (`ProtectSystem=strict`, `StateDirectory=fprint`)

This is the same model as distro fprintd. Upstream treats stored prints
as closer to a username than a password
([fprintd issue 16](https://gitlab.freedesktop.org/libfprint/fprintd/-/issues/16);
Ubuntu MIR). Root on the machine can read the pixels. Full-disk
encryption on the host covers the store at rest when the disk is locked.

`uninstall.sh` leaves `/var/lib/fprint/` in place so a reinstall can
still verify. Remove prints with `fprintd-delete "$USER"`.

### Diagnostic capture dumps

`sf514-egis0570-capture` writes binary PGM frames plus a stats text
file. Default directory `fingerprint/captures/` (also
`scripts-fingerprint-fix/fingerprint/` if you copy there). Both paths
are gitignored. These files **are** fingerprint images.

The capture tool now creates the leaf output directory at mode 0700
and each PGM at mode 0600 (`open` + `fchmod`). Older dumps from
before that change may still be umask-default (often 0644); delete
or `chmod 600` those files. Delete dumps when diagnosis is done.

The udev rule `70-sf514-egis0570.rules` tags the pad `uaccess`, so
the **logged-in seat user** can claim USB `1c7a:0570` and dump frames
without being root. That is only for the capture tool. fprintd opens
the pad as root. Only one process can claim the interface: stop
fprintd first. A seat user with the capture binary can collect a live
image of whoever presses the pad while fprintd is stopped. They still
cannot read `/var/lib/fprint/` without root.

### Overlay library on the login path

Install copies a full `libfprint-2.so.2` to `/var/usrlocal/lib64/`
(mode 0755) and points dbus-activated fprintd at it with
`LD_LIBRARY_PATH`. That `.so` is the matcher and the USB driver for
every fprintd request, including PAM. Write access to
`/var/usrlocal/lib64` is equivalent to replacing the login matcher.
Keep that directory root-owned. The installer uses `install(1)` and
`restorecon` (`lib_t`) so `fprintd_t` can mmap it.

Journal lines from the overlay are scores and frame statistics
(`score=`, `probe_mean=`, `probe_skin=`). They do not dump pixels.

### Matcher false-accept

`EGIS0570_MATCH_THRESHOLD` is 0.48. Verify takes the **best** score
across nine gallery frames and three live hold bursts. Adjacent
fingers on the same hand are the hard case on a 114×57 landscape
strip. There is no other-finger corpus yet, so the false-accept rate
is unmeasured. Do not lower the threshold to chase 5/5. Stock NBIS
`bz3_threshold` 25 on this pad size was already a weak control.

### Host steps

- Leave `/var/lib/fprint/` 0700 and root-owned.
- Delete capture dumps after use (`rm -r fingerprint/captures`).
- Do not copy PGM files into chat, git, or cloud sync.
- After uninstall, run `fprintd-delete "$USER"` if those templates
  should go with the overlay.
- Keep `/var/usrlocal/lib64` root-owned.

## Findings

Live on this chassis. Threshold stays 0.48; do not lower it to chase
5/5.

### Stock Fedora treats a press pad as a swipe

Host `libfprint` / `fprintd` already bind USB `1c7a:0570`. There is no
missing kernel module. The in-tree driver keeps a 17-row strip from
each 57-row frame and concatenates strips as if the user swiped. A
held finger produces five nearly identical 114×57 frames ~20 ms apart.
Matching is NBIS/BOZORTH3 (`bz3_threshold` 25). Enumeration works;
usable login does not. That is libfprint issue #418.

This overlay waits for a press, holds several bursts, stores the
114×57 pixels as `FPI_PRINT_RAW`, and matches with contrast-normalize
plus NCC. Image-device NBIS serialization would drop those pixels.

### Windows init vs stock init

Stock libfprint init on this pad returns five 114×57 frames with mean
~246 whether empty or held — no contrast. The 30-packet Windows /
tmullender sequence (`--init windows`) gives empty mean ~153 and
finger mean ~212, with visible ridges after `frame - empty` (present
mean ~59, stddev ~17). Overlay `egis0570.h` uses that list. Do not
send `libusb_reset_device` or `libusb_set_configuration`.

### Finger is brighter than empty

Subtract polarity is frame minus empty background. Do not invert.
Background is the per-pixel MIN of the first empty burst. If the first
burst is already a finger, later presses look empty (mean ~5) and
never enroll.

Present gate after subtract: mean ≥ 18 and stddev ≥ 7. Three
consecutive present captures count as a hold.

### Matcher

Clean-room z-score NCC in `egis0570-ridge.c`: stddev floor 1.0, clamp
±3, rotation ±15°, translation ±20 px step 1, geometric min overlap
0.45 of the 114×57 pad. `EGIS0570_MATCH_THRESHOLD` is 0.48.

Tried and dropped on live re-presses against this pad:

| Attempt | Live result |
| --- | --- |
| Independent per-frame Gabor then NCC | scores 0.21–0.40, under 0.48 |
| Whole-frame z-score NCC | first usable passes (0.65 and 0.49) |
| Bright-pixel mask (threshold 12) then Pearson | full-coverage presses (`probe_skin` 0.99–1.00, mean ~50) fell to 0.28–0.38 |
| Tight enroll quality gate (mean ≥ 28, skin ≥ 0.55) | enroll itself became too hard |

The pad lights under a portrait finger (`probe_skin` typically 0.7–1.0).
A bright-pixel mask is the wrong proxy: same-hold capture dumps with
40% zeros are not a re-press test. Do not restore that mask.

Same-hold dump NCC (~0.90) is also not a re-press test. Tune the
threshold only from a same-finger / other-finger corpus. There is no
other-finger corpus yet.

### Three fingertip strips

The sensing area is landscape 114×57. A finger sits portrait, so a
press is one horizontal strip of the fingertip. Phone-side sensors
force full coverage by geometry; this one does not. Sliding toward
the nail or the joint is a different strip.

Enroll is three sections. A new strip that scores ≥ 0.50 against a
stored one is retried (`enroll-finger-not-centered`). Each section
stores all three hold bursts, so the gallery is `aay` × 9. Verify
takes the best score across every stored frame and the three live
hold bursts.

Eight identical-height stages and a mean/skin quality gate both
failed on this pad: people cannot place the finger on the same
pixels every time, and the pad cannot see the whole vertical
fingertip at once.

### Live quality vs Windows

Official Windows driver on this chassis is about 3–4 successful
unlocks out of 5. After the three-strip gallery, live overlay verifies
on the same pad reached that bar. Example session (threshold 0.48,
`gallery_frames=9`):

| score | result |
| --- | --- |
| 0.5453 | pass |
| 0.4870 | pass |
| 0.2852 | miss |
| 0.5043 | pass |
| 0.2320 | miss |
| 0.4967 | pass |
| 0.5410 | pass |

That is 5/7 in this sample, in the same band as Windows. Misses still
happen with a well-placed finger. Do not lower the threshold to chase
5/5.

### Overlay load on ostree

- Write only `/var/usrlocal` and `/etc`. Do not `rpm-ostree override`
  `/usr/lib64/libfprint-2.so.2`.
- `fprintd` `ProtectSystem=strict` still reads `/var`. SELinux type on
  the overlay `.so` must be `lib_t` or `fprintd_t` will not mmap it.
- Silverblue maps `/var/usrlocal` equivalent to `/usr/local`. `semanage
  fcontext` under `/var/usrlocal` is rejected there; `restorecon` is
  enough when `matchpathcon` already returns `lib_t`.
- `cp -a` from `$HOME` leaves the drop-in `user_home_t`. PID 1 lists
  it in DropInPaths and still cannot parse `Environment=`, so
  `LD_LIBRARY_PATH` never applies. Copy with `install(1)` and
  restorecon to `systemd_unit_file_t`.
- Reload systemd **before** udev. USB add can dbus-start fprintd on
  the old unit.
- fprintd is dbus-activated and exits after ~30 s idle. `pidof` /
  `/proc/<pid>/maps` can be empty because the process is gone. A
  regular user often cannot read those maps (ptrace). `verify.sh`
  falls back to `systemctl cat`.
- Overlay vs stock: `busctl get-property` on
  `net.reactivated.Fprint.Device` `scan-type` is `press` vs `swipe`.

### Enroll placement messages (reverted)

A PATH wrapper around `fprintd-enroll` plus a GNOME `notify-send`
user unit was tried so enroll would say “move your finger a bit”
between stages. It never showed a message in use, and it was too
much machinery. It is gone. `install.sh` still deletes leftover
`/var/usrlocal/bin/fprintd-enroll` if that file is present.

## Capture dumps (no overlay required)

Only one process can claim the pad. Stop fprintd first. Live dumps
are fingerprint images: gitignored, leaf directory 0700, files 0600.
See [Security](#security). Delete them when diagnosis is done.

```bash
make -C fingerprint/capture
sudo systemctl stop fprintd.service
# empty pad: press Enter with no finger on the sensor
sudo ./fingerprint/capture/sf514-egis0570-capture \
  --wait --init windows --output-dir fingerprint/captures --label empty --bursts 2
# finger already on the pad (below the arrow keys) before Enter
sudo ./fingerprint/capture/sf514-egis0570-capture \
  --wait --init windows --output-dir fingerprint/captures --label finger --bursts 8
```

`--wait` pauses until Enter. Capture is one fast burst; without
`--wait` a “finger” run can still be empty.

Matcher self-test (no pad required):

```bash
make -C fingerprint/overlay self-test
```

Score two captured PGM frames with the same matcher the overlay uses:

```bash
./fingerprint/overlay/sf514-egis0570-ridge-eval \
  fingerprint/captures/finger-000-frame0.pgm \
  fingerprint/captures/finger-000-frame1.pgm
```

## Limits (fingerprint v1)

- Matcher threshold 0.48 is a starting point. A too-low value accepts
  the wrong finger. Do not lower it to chase 5/5.
- 114×57 is a small landscape pad with a portrait finger. Adjacent
  fingers on the same hand are the hard case. No other-finger corpus
  yet.
- fprintd `ProtectSystem=strict` plus SELinux `fprintd_t` require the
  drop-in and `lib_t` on the overlay `.so`. A raw copy into
  `/var/usrlocal` without `restorecon` will fail to mmap.
- Overlay `.so` must be rebuilt on the distro that runs fprintd
  (`fingerprint/build-overlay.sh`).
- Enrolled templates and capture dumps are unencrypted ridge images.
  Details: [Security](#security).

## Upstream

libfprint lives on GitLab
([gitlab.freedesktop.org/libfprint/libfprint](https://gitlab.freedesktop.org/libfprint/libfprint)).
The swipe `egis0570` driver is already in libfprint since v1.92.1
(GitHub [indev29/egis0570](https://github.com/indev29/egis0570) is
archived). There is no GitHub project that accepts libfprint driver
PRs.

This overlay is a chassis-tuned press-mode layer (Windows init,
three-strip `FPI_PRINT_RAW` gallery, 0.48 z-score NCC) without an
other-finger FAR corpus or a distinctive `full_name`. This repo is
the delivery path. A later GitLab merge request would need a FAR
corpus, a generic press-mode driver (or a new id so it can coexist
with swipe `egis0570`), and tests. That work is out of v1.

Audio already has GitHub PRs on
[alsa-ucm-conf#871](https://github.com/alsa-project/alsa-ucm-conf/pull/871)
and
[alsa-ucm-conf#571](https://github.com/alsa-project/alsa-ucm-conf/pull/571).
No extra fingerprint GitHub PR.

## License

Repo overlay helpers are [Unlicense](../LICENSE). `fingerprint/overlay/egis0570.c`
and `egis0570.h` are derived from
[libfprint](https://gitlab.freedesktop.org/libfprint/libfprint) and
remain [LGPL-2.1-or-later](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).
