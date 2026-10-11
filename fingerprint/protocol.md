# EgisTec 1c7a:0570 protocol notes (Acer Swift SF514-52T)

The pad node is `root:root` `0664` without `uaccess` until this overlay's
udev rule is installed, so the capture tool needs root or a seat ACL.
`scripts-fingerprint-fix/install.sh` installs that rule. Inside distrobox
the node may show up as `nobody:nobody` `0664`; libusb_open still fails
until the host udev ACL is present or the tool runs as host root.

Only one process can claim the pad. Keep `fprintd.service` stopped while
the capture tool runs. Live dumps are fingerprint images (gitignored);
the tool writes the leaf directory at mode 0700 and each file at 0600.

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

`--init stock` is the in-tree libfprint list. `--init windows` (default)
is the tmullender/egis-eh570 list. `--wait` pauses until Enter so a
finger can already be on the pad; capture is one fast burst.

## Unit identity

| Field | Value |
| --- | --- |
| DMI | Acer Swift SF514-52T, BIOS V1.11, board Carlsberg_KL |
| USB | `1c7a:0570` EgisTec Touch Fingerprint Sensor |
| Serial | `070D612F` (USB string; DMI/lsusb also reported `W70D612F`) |
| bcdDevice | 10.41 (`1041`) |
| product | EgisTec Touch Fingerprint Sensor |
| Endpoints | bulk OUT `0x04`, bulk IN `0x83`, interface 0, config 1 |

## Wire format

- Command: 7 bytes, ASCII `EGIS` + `cmd` + `reg` + `value`
- Register-write reply: 7 bytes, ASCII `SIGE` + 3 bytes
- Capture command `06 00 fe`: reply is **32512** bytes = five `114×57` frames (6498×5 = 32490) + 22 trailing bytes

Further frames use the 4-packet repeat sequence (same for stock and
windows). Both lists live in `fingerprint/capture/sf514_egis0570_capture.c`.
The overlay `fingerprint/overlay/egis0570.h` uses the windows list.

Do not send `libusb_reset_device` or `libusb_set_configuration` on this
pad. Those re-enumerate related Egis parts (EH577).

## Init sequences

Stock (in-tree libfprint `egis0570`, 23 packets, last is capture):

- Gain `0x20`/`0x58` = `0x3f`
- `0x22`/`0x56` = `0x03`, `0x24`/`0x54` = `0x01`
- `0x16` = `0x3e`, `0x09` = `0x0b`, `0x14` = `0x03`

Windows (tmullender/egis-eh570 `demo.c`, 30 packets, last is capture):

- F-start: `01 0d 00`, `01 0e 00`, `01 02 1f`, `01 05 08`, `01 03 ff`
- Then `0x10`–`0x13` (same as stock), then gain `0x20`/`0x58` = `0x41`
- `0x22`/`0x56` = `0x02`, `0x24`/`0x54` = `0x00`, extra `0x25`/`0x53` = `0x00`
- `0x16` = `0x41`, `0x09` = `0x0a`, `0x14` = `0x00`

Repeat (both): `01 02 0f`, `00 02 0f`, `01 02 2f`, `06 00 fe`.

## Empty vs finger (this unit)

Stock init, no `--wait`: empty and finger were the same (~mean 246.5,
stddev ~10.8). No contrast, so `finger-present` stayed false.

Windows init with `--wait`, fprintd stopped. Finger is brighter than
empty. After `frame - min(empty burst)`: empty mean 1.25 stddev 1.45
(absent); finger mean 59.40 stddev 17.10 (present). Ridges are visible
in the subtracted PGM. Subtract polarity is `frame - background`
(finger brighter). Do not invert.

| Label | Burst | Frame | mean | stddev | min | max | all_zero | washed_out |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| empty | 0 | 0 | 153.31 | 20.12 | 114 | 232 | 0 | 0 |
| empty | 0 | 1 | 153.61 | 19.88 | 114 | 232 | 0 | 0 |
| empty | 0 | 2 | 153.12 | 20.00 | 114 | 232 | 0 | 0 |
| empty | 0 | 3 | 153.07 | 19.97 | 114 | 232 | 0 | 0 |
| empty | 0 | 4 | 153.22 | 19.82 | 114 | 230 | 0 | 0 |
| empty | 1 | 0 | 152.97 | 19.88 | 114 | 232 | 0 | 0 |
| empty | 1 | 1 | 153.19 | 19.90 | 114 | 232 | 0 | 0 |
| empty | 1 | 2 | 153.05 | 19.91 | 112 | 232 | 0 | 0 |
| empty | 1 | 3 | 153.03 | 19.78 | 114 | 230 | 0 | 0 |
| empty | 1 | 4 | 153.16 | 19.93 | 114 | 232 | 0 | 0 |
| finger | 0 | 0 | 211.46 | 23.88 | 150 | 254 | 0 | 0 |
| finger | 0 | 1 | 211.91 | 23.95 | 146 | 254 | 0 | 0 |
| finger | 0 | 2 | 212.52 | 23.78 | 148 | 254 | 0 | 0 |
| finger | 0 | 3 | 211.18 | 23.84 | 146 | 254 | 0 | 0 |
| finger | 0 | 4 | 212.15 | 23.86 | 146 | 254 | 0 | 0 |
| finger | 7 | 0 | 212.63 | 23.65 | 138 | 254 | 0 | 0 |
| finger | 7 | 4 | 212.90 | 23.82 | 150 | 254 | 0 | 0 |

Finger-present gate: after subtracting the empty-pad background, mean ≥ 18 and stddev ≥ 7.

## Init ACK behaviour

The capture tool treats a 7-byte IN after every non-final packet as success. If a packet times out, note the index here; that is the first place to try the other `--init` list.
