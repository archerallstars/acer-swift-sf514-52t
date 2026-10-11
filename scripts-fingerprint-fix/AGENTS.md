# Agent instructions — fingerprint fix

Load-bearing rules for `scripts-fingerprint-fix/`, `fingerprint/`,
`systemd/sf514-egis0570.conf`, and `udev/70-sf514-egis0570.rules`.
Breaking these will either miss the pad or replace ostree `libfprint`.

User-facing steps: `scripts-fingerprint-fix/README.md`. Repo-wide
layering: root `AGENTS.md`. Chassis index: root `README.md`.

## Do not

- `rpm-ostree override` or otherwise replace
  `/usr/lib64/libfprint-2.so.2`. fprintd loads the overlay through
  `LD_LIBRARY_PATH=/var/usrlocal/lib64`.
- Copy anything into ostree `/usr`.
- Lower `EGIS0570_MATCH_THRESHOLD` in `fingerprint/overlay/egis0570.h`
  just to make one unlock succeed. Tune it from a same-finger /
  other-finger corpus.
- Delete `/var/lib/fprint/` from `uninstall.sh`.
- Touch `scripts-audio-fix/`, `ucm2/`, or the ALSA systemd units.
- Turn this driver back into `FpImageDevice`. Image-device enroll
  serializes NBIS and drops the 114×57 pixels this matcher stores as
  `FPI_PRINT_RAW`.

## Hardware

- Pad is USB `1c7a:0570` (this chassis serial `W70D612F`), below the
  arrow keys, press not swipe. Stock Fedora `egis0570` enumerates it
  and still cannot enroll.
- The sensing area is landscape 114×57. A finger sits portrait on
  it, so a press is one horizontal strip of the fingertip. Sliding
  the finger toward the nail or the joint is a different strip.
  Phone-side sensors force full coverage by geometry; this one
  does not. Live verifies still show probe_skin 0.7–1.0 (the pad
  lights up). Do not bring back a bright-pixel mask: it dropped
  full-coverage re-press scores from ~0.65 to ~0.36.
- Official Windows driver on this chassis is about 3–4 accepts out
  of 5. That is the quality bar. Do not lower MATCH_THRESHOLD to
  chase 5/5.
- Bulk OUT `0x04`, bulk IN `0x83`, 32512-byte captures = five 114×57
  frames. Protocol: `fingerprint/protocol.md`.

## Overlay

- Driver sources live in `fingerprint/overlay/`. Build with
  `fingerprint/build-overlay.sh` (libfprint 1.94.10, `-Ddrivers=egis0570`).
- Matcher is clean-room contrast-normalize plus NCC in
  `egis0570-ridge.c` (translation ±20 px). Verify takes the best
  score across the three hold bursts and every stored enroll strip.
  Enroll is three sections (nail / centre / joint). A section that
  scores ≥ 0.50 against an already stored strip is retried
  (`FP_DEVICE_RETRY_CENTER_FINGER`) so the gallery covers different
  heights on the fingertip. Each section stores every hold burst.
  Do not bring back the mean≥28 / skin≥0.55 enroll gate. No vendor
  engine unless Phase 4 on a live corpus fails.
- `systemd/sf514-egis0570.conf` must keep `LD_LIBRARY_PATH` on
  `/var/usrlocal/lib64` so it works when `/usr/local` is not a symlink.
- Overlay files always go under `/var/usrlocal` and `/etc`, never
  `/usr`. That is the same on ostree and on a mutable root.
- SELinux type on the overlay `.so` must be `lib_t` (`restorecon`)
  when SELinux is on. If `/var/usrlocal` = `/usr/local` equivalency
  exists, the fcontext spec is `/usr/local/lib64/libfprint-2\.so(\..*)?`.
  Without that equivalency, the spec is `/var/usrlocal/lib64/...`.
  Skip SELinux on hosts where `/sys/fs/selinux/enforce` is missing.
  `fprintd_t` will not mmap `tmp_t`.
- Copy drop-in and udev files with `install(1)`. `cp -a` from `$HOME`
  keeps `user_home_t`; systemd then lists the drop-in in DropInPaths
  and still cannot parse `Environment=`. restorecon to
  `systemd_unit_file_t` and `udev_rules_t`.
- AppArmor: if a fprintd profile exists, append a local `mr` rule for
  `/var/usrlocal/lib64/libfprint-2.so*`. No-op when AppArmor is off.
- `udev/70-sf514-egis0570.rules` is only for the capture tool (seat
  `uaccess`). fprintd opens the pad as root.

## Install / uninstall / verify

- `install.sh` copies `fingerprint/dist/` plus the drop-in and udev
  rule. Reload systemd before the udev trigger, because USB add can
  dbus-start fprintd. Then stop fprintd, daemon-reload until DropInPaths
  lists the drop-in, and start. `uninstall.sh` reverses that set only,
  with the same order. Install also deletes a leftover
  `/var/usrlocal/bin/fprintd-enroll` wrapper if one is present.
- `verify.sh` plumbing needs no finger and no root. `/proc/<fprintd>/maps`
  is often unreadable for a regular user; fall back to `systemctl cat`.
  `--live` waits on the pad.
- Host, not the container: scripts re-exec via `distrobox-host-exec`.

## Capture tool

- Claims the USB pad exclusively: stop fprintd first. Installed binary
  `/var/usrlocal/bin/sf514-egis0570-capture`. Default output dir
  `fingerprint/captures`.
- `--wait` pauses until Enter so a finger can already be on the pad.
  Capture is one fast burst; without `--wait` a "finger" run can still
  be empty.
- `--init windows` (default) is the tmullender/egis-eh570 sequence.
  `--init stock` is in-tree libfprint. Overlay `egis0570.h` uses the
  windows list (empty mean ~153, finger mean ~212 on this pad).
- Do not add `libusb_reset_device` or `libusb_set_configuration`.
- Live dumps are fingerprint images. Write the leaf output directory
  at mode 0700 and each PGM at mode 0600. Keep both capture paths
  gitignored. Do not commit dumps.

## Out of v1 unless the user asks

- Vendor match-on-host engine.
- Upstreaming the press-mode driver to libfprint (GitLab
  gitlab.freedesktop.org/libfprint/libfprint). There is no GitHub
  project that would take this overlay as a PR. GitHub
  indev29/egis0570 is archived; swipe egis0570 is already in
  libfprint v1.92.1.
