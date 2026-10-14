# Agent instructions — BIOS Setup access fix

Load-bearing rules for `scripts-bios-fix/`. Breaking these will
leave the user without a way to enter BIOS Setup on this Acer
Insyde firmware.

User-facing steps: `scripts-bios-fix/README.md`. Repo-wide
layering: root `AGENTS.md`. Chassis index: root `README.md`.

## Do not

- Target any bootloader other than Limine. Fedora Silverblue
  (GRUB2 + shim) works fine with Secure Boot on this
  chassis. Only Limine EFI entries cause the F2 hang. The
  scripts must never delete Fedora, GRUB, or other entries.
- Try to patch Limine. This is an Acer Insyde firmware bug,
  not a Limine bug. Removing the Limine NVRAM entry is the
  only userspace fix.
- Auto-delete boot entries without explicit per-entry confirmation.
  Deleting the wrong entry (e.g. Windows Boot Manager) can make
  the situation worse.
- Delete the `Windows Boot Manager` NVRAM entry or
  `\EFI\Microsoft\Boot\bootmgfw.efi`. The firmware's special-case
  code for Windows Boot Manager may keep the setup path alive.
- Touch `scripts-audio-fix/`, `scripts-fingerprint-fix/`,
  `scripts-igpu-fix/`, `ucm2/`, `systemd/`, `fingerprint/`, or
  `udev/`.
- Copy anything into `/usr`. This fix installs no payload.
- Run `sudo ./scripts-bios-fix/restore-bios-access.sh` on this
  machine unless the user asks.

## Hardware

- BIOS is Insyde Corp V1.11 on board Carlsberg_KL. The firmware
  hangs on the Acer logo when F2 is pressed and a Limine EFI
  entry exists in NVRAM. F12 boot menu and `systemctl reboot
  --firmware-setup` may also hang.
- Fedora Silverblue 44 with GRUB2 + shim and Secure Boot works
  fine on this chassis. The hang is specific to Limine EFI
  entries on Acer Insyde firmware.
- After deleting the Limine entry, F2 works again. The user must
  then set a supervisor password, use "Select an UEFI file as
  trusted for executing" to whitelist `limine_x64.efi`, and
  re-add the entry with `efibootmgr --create`.

## Recovery flow

- `restore-bios-access.sh` is interactive. It lists NVRAM entries,
  highlights Limine entries only, and asks for confirmation before
  each `efibootmgr --delete-bootnum`. It never deletes without a
  typed `yes`. It never touches Fedora, GRUB, or Windows entries.
- `verify.sh` needs no root. It reports Limine entry status,
  Windows Boot Manager presence, and prints the Limine `S`-key
  reminder. It does not mutate anything.
- Host, not the container: `restore-bios-access.sh` re-execs via
  `distrobox-host-exec sudo`. `verify.sh` re-execs as the same user.

## Out of v1 unless the user asks

- A systemd unit that watches for new Limine EFI entries and warns.
- An install.sh/uninstall.sh pair (this fix has no persistent
  payload).
- A UEFI variable write to disable the F2 hang path (not possible
  from userspace).
