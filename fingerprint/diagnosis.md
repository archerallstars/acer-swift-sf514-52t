# Why stock Fedora `egis0570` never enrolled on this pad

## What Fedora already does

Host `libfprint-1.94.100` / `fprintd-1.94.5` already bind USB `1c7a:0570`. `fprintd-list` names the device. There is no missing kernel module.

The in-tree driver is a **swipe** assembler:

- It keeps only a 17-row strip from each 57-row frame (`EGIS0570_RFMGHEIGHT`).
- It concatenates strips with movement estimation as if the user swiped.
- This chassis is a **press** pad. A held finger produces five nearly identical 114×57 frames ~20 ms apart, not a swipe.
- Matching is NBIS/BOZORTH3 with `bz3_threshold` 25, which the in-tree comments already call a security joke on this sensor size.

That combination is libfprint issue #418: enumeration works, usable login does not.

## What this overlay changes

1. Press-mode capture: wait for finger, hold several bursts, pick the highest-contrast 114×57 frame, wait for lift.
2. Templates stored as `FPI_PRINT_RAW` (the 114×57 pixels), so they survive reboot. Image-device NBIS serialization would drop the pixels.
3. Clean-room contrast-normalize plus NCC matcher (`egis0570-ridge.c`).
   The pad is landscape 114×57; a finger sits portrait. Official
   Windows driver on this chassis is about 3–4 accepts out of 5;
   that is the quality bar. Independent per-frame Gabor was dropped:
   live re-press scores fell to 0.21–0.40 against threshold 0.48.
   Z-score NCC then passed 2 of 8 live verifies (0.65 and 0.49),
   plus 0.52 during the next install (old .so, first try). A
   bright-pixel mask then dropped full-coverage re-presses
   (`probe_skin` 0.99–1.00, mean ~50) to 0.28–0.38. Live presses
   already light most of the pad; same-hold capture dumps at 40%
   zeros were the wrong proxy. Threshold stays 0.48. No vendor
   DLL. Synthetic self-test: `make -C fingerprint/overlay self-test`.

Stock NBIS is the baseline we expect to fail on 114×57. The overlay does not ship it as the login matcher.

## Live enroll log (Phase 2)

Run on the host with the **stock** driver, before install, if you still need a log of the swipe path:

```bash
sudo systemctl stop fprintd.service
sudo G_MESSAGES_DEBUG=all /usr/libexec/fprintd
# other terminal:
fprintd-enroll
```

After the overlay is installed, `fprintd-enroll` should complete 3
press stages (nail / centre / joint). A stage that matches an
already stored strip at ≥ 0.50 is retried. `fprintd-verify` should
accept that finger most of the time (Windows on this pad is about
3–4 out of 5) and reject a different one.

Live enroll saved `right-index-finger`. Gallery is `aay` × 8.

Z-score NCC verifies: 0.3235, 0.6478 (pass), 0.2361, 0.1912, 0.4200,
0.4915 (pass), 0.3035, 0.2315, then 0.5165 (pass) on the first press
during the next `install.sh` (old .so, no `probe_skin=`).

Bright-pixel-mask verifies (new .so, `probe_skin=` present): eleven
presses 0.23–0.38, including three with `probe_skin` 0.99–1.00 and
mean 50–52. Matcher reverted to z-score NCC.

Z-score NCC against the first enrollment, 14 live verifies: one
pass (0.5534), six near-misses 0.43–0.47, rest 0.30–0.39. 1/14 is
below the Windows 3–4/5 bar. The tight enroll quality gate
(mean ≥ 28, skin ≥ 0.55) then made enroll itself too hard. Enroll
is now three fingertip strips in a consecutive sweet band: a new
strip ≥ 0.50 against a stored one is the same height (slide more);
≤ 0.25 against every stored strip jumped a gap (slide less). Each
strip stores all three hold bursts. Verify already takes the best
score against every stored frame. Threshold stays 0.48 until an
other-finger corpus exists. Sweet-band enroll is live-tested on this
chassis. Journal: `verify score=`, `probe_skin=`, `hold_frames=`,
`enroll section=`, `too_similar_at=`, `too_far_at=`.

## Live pad images (this chassis)

Stock libfprint init on this pad returns five 114×57 frames with mean
~246.5 whether empty or held. Windows init (`--wait --init windows`)
gives empty mean ~153 and finger mean ~212, with visible ridges after
`frame - empty` (present mean 59, stddev 17). Overlay `egis0570.h` now
uses that init. Rebuild the overlay `.so` and reinstall before enroll.

## Matcher gate

Do not lower `EGIS0570_MATCH_THRESHOLD` in `egis0570.h` just to make one unlock succeed. Tune it from a small same-finger / other-finger corpus dumped by the capture tool (`--label finger` vs another finger).
