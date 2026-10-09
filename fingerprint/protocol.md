# EgisTec 1c7a:0570 protocol notes (Acer Swift SF514-52T)

The pad node is `root:root` `0664` without `uaccess` until this overlay's
udev rule is installed, so the capture tool needs root or a seat ACL.
`scripts-fingerprint-fix/install.sh` installs that rule. Inside distrobox
the node may show up as `nobody:nobody` `0664`; libusb_open still fails
until the host udev ACL is present or the tool runs as host root.

Captured on this chassis. Fill in live numbers after running:

```bash
make -C fingerprint/capture
# stop fprintd if libusb reports BUSY
sudo systemctl stop fprintd.service
./fingerprint/capture/sf514-egis0570-capture --output-dir fingerprint/captures --label empty --bursts 2
./fingerprint/capture/sf514-egis0570-capture --output-dir fingerprint/captures --label finger --bursts 2
sudo systemctl start fprintd.service   # optional; dbus will restart it
```

## Unit identity

| Field | Value |
| --- | --- |
| DMI | Acer Swift SF514-52T, BIOS V1.11, board Carlsberg_KL |
| USB | `1c7a:0570` EgisTec Touch Fingerprint Sensor |
| Serial | `W70D612F` (from earlier lsusb; confirm in `fingerprint/captures/usb-descriptor.txt`) |
| bcdDevice | 10.41 |
| Endpoints | bulk OUT `0x04`, bulk IN `0x83`, interface 0, config 1 |

## Wire format

- Command: 7 bytes, ASCII `EGIS` + `cmd` + `reg` + `value`
- Register-write reply: 7 bytes, ASCII `SIGE` + 3 bytes
- Capture command `06 00 fe`: reply is **32512** bytes = five `114×57` frames (6498×5 = 32490) + 22 trailing bytes

Init is 23 packets (last is capture). Further frames use the 4-packet repeat sequence. Both lists are in `fingerprint/capture/sf514_egis0570_protocol.h` and `fingerprint/overlay/egis0570.h`.

## Empty vs finger (this unit)

Recorded from capture dumps:

| Burst | Frame | mean | stddev | all_zero | washed_out |
| --- | --- | --- | --- | --- | --- |
| *(run the capture tool and paste rows)* | | | | | |

Finger-present gate used by the overlay driver: after subtracting the empty-pad background, mean ≥ 18 and stddev ≥ 7.

## Init ACK behaviour

The capture tool treats a 7-byte IN after every non-final packet as success. If a packet times out, note the index here; that is the first place to try the commented alternate init sequence in upstream `egis0570.h`.
