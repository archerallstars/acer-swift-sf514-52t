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
3. Clean-room Gabor + NCC matcher (`egis0570-ridge.c`). One global
   ridge orientation (per-block fields on 114×57 were not translation
   stable). No vendor DLL. Synthetic self-test:
   `make -C fingerprint/overlay self-test`.

Stock NBIS is the baseline we expect to fail on 114×57. The overlay does not ship it as the login matcher.

## Live enroll log (Phase 2)

Run on the host with the **stock** driver, before install, if you still need a log of the swipe path:

```bash
sudo systemctl stop fprintd.service
sudo G_MESSAGES_DEBUG=all /usr/libexec/fprintd
# other terminal:
fprintd-enroll
```

After the overlay is installed, `fprintd-enroll` should complete 8 press stages without hanging. `fprintd-verify` should accept that finger and reject a different one.

## Matcher gate

Do not lower `EGIS0570_MATCH_THRESHOLD` in `egis0570.h` just to make one unlock succeed. Tune it from a small same-finger / other-finger corpus dumped by the capture tool (`--label finger` vs another finger).
