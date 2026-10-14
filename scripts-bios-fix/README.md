# BIOS Setup access — Insyde firmware hang (Limine)

Back to the [chassis README](../README.md).

Workaround and recovery for an **Acer Insyde firmware bug**: when a
**Limine** EFI boot entry exists in NVRAM, pressing **F2** (BIOS
Setup) hangs forever on the Acer logo. The boot menu key (F12) and
`systemctl reboot --firmware-setup` may also hang.

This is **not a Limine bug** — it is an Acer Insyde firmware bug.
Fedora Silverblue (systemd-boot + shim) works fine with Secure Boot
on this chassis. The hang is specific to Limine EFI entries.

| | |
| --- | --- |
| Machine | Acer Swift SF514-52T |
| BIOS | Insyde Corp V1.11 |
| Bootloader | Limine (via Omarchy) |
| Symptom | F2 hangs on Acer logo; BIOS Setup unreachable |
| Root cause | Acer Insyde firmware — Limine EFI entry in NVRAM |

```
scripts-bios-fix/restore-bios-access.sh  interactive recovery (delete Limine EFI entry)
scripts-bios-fix/verify.sh               check NVRAM Limine entry status and Windows Boot Manager presence
```

No system payload is installed. This fix is documentation plus an
optional recovery tool. Nothing is copied into `/usr`, `/etc`, or `/var`.

## The problem

On Acer laptops with Insyde firmware, the BIOS Setup path (F2) hangs
when a **Limine** EFI boot entry is present in NVRAM. This is a
firmware bug — Acer's UEFI has hardcoded special treatment for
Windows Boot Manager and breaks on Limine entries. Fedora Silverblue
(systemd-boot + shim) works fine with Secure Boot on this chassis.

Reports on Acer + Limine (2025–2026):

| Source | Date | Bootloader |
| --- | --- | --- |
| [CachyOS forum](https://discuss.cachyos.org/t/couldnt-boot-into-uefi-firmware-for-some-reason/14071) | Aug 2025 | Limine |
| [CachyOS forum](https://discuss.cachyos.org/t/no-bios-access-after-cachyos-install/32156) | Jun 2026 | Limine |
| [Acer Community](https://community.acer.com/en/discussion/727197) | Jul 2025 | Limine |

Reports on Acer + systemd-boot (same firmware class):

| Source | Date | Bootloader |
| --- | --- | --- |
| [Arch BBS SOLVED](https://bbs.archlinux.org/viewtopic.php?id=300026) | Oct 2024 | systemd-boot |
| [Arch Wiki: Acer Swift Go SFG16-72](https://wiki.archlinux.org/title/Acer_Swift_Go_SFG16-72) | Dec 2025 | systemd-boot |

**Not fixed.** Acer has not released a firmware update for this. The
bug is Acer's, not Limine's. On this chassis the hang is specific to
Limine entries — Fedora Silverblue works fine.

## Workarounds (ranked)

### 1. Delete the Limine EFI entry with `efibootmgr` (proven)

Once the Limine entry is deleted, F2 BIOS Access is restored
immediately. Then set up the firmware properly and re-add the
bootloader:

```bash
# Find the Limine entry
efibootmgr

# Delete it (replace 000X with your entry number)
efibootmgr --delete-bootnum --bootnum 000X
# Reboot → F2 now works
```

Or use the interactive helper (only offers Limine entries):

```bash
sudo ./scripts-bios-fix/restore-bios-access.sh
```

Then inside BIOS Setup:

1. Set a **supervisor password** (required to unlock Secure Boot
   options on Acer).
2. Enable **Secure Boot**.
3. Use **"Select an UEFI file as trusted for executing"** → select
   `\EFI\limine\limine_x64.efi` (or your bootloader path).
4. Disable Secure Boot again (if you do not want it).
5. Re-add the bootloader entry:

```bash
sudo efibootmgr --create \
  --disk /dev/nvme0n1 --part 1 \
  --label "Limine" \
  --loader '\EFI\limine\limine_x64.efi'
```

### 2. Limine's built-in `S` key — Firmware Setup

Limine shows `S Firmware Setup` in the menu header. Press **S** to
reboot into UEFI firmware settings. This bypasses the F2 hang. (One
user reported it takes ~5 minutes on Acer firmware; it works.)

### 3. `systemctl reboot --firmware-setup`

Works on some Acer models; hangs on others. Worth trying first.

### 4. Keep Windows Boot Manager entry intact

Even if you wipe Windows, **keep** the `Windows Boot Manager` EFI
NVRAM entry and `\EFI\Microsoft\Boot\bootmgfw.efi` on the ESP. The
firmware's special-case code for Windows Boot Manager may be what
keeps the setup path alive.

### 5. Physical fallback

Remove the NVMe SSD → boot (BIOS is accessible with no Linux boot
entries) → reinsert SSD. Last resort.

## Verify

```bash
./scripts-bios-fix/verify.sh
```

Checks Limine NVRAM entry status, Windows Boot Manager presence, and
prints the Limine `S`-key reminder. Needs no root.

## Does this survive Omarchy updates?

**Yes.** The fix has three parts, and each survives:

| Component | Survives? | Why |
| --- | --- | --- |
| This recovery tool | ✅ | Lives in this repo, not Omarchy |
| Firmware whitelist of `limine_x64.efi` | ✅ | Firmware setting, not OS state |
| Limine binary path | ✅ | Omarchy replaces the binary in-place |
| Limine NVRAM entry | ⚠️ | Not re-created on updates; `omarchy-reinstall` might |

The firmware whitelist ("Select an UEFI file as trusted for
executing") is **path-based** on Insyde. Once
`\EFI\limine\limine_x64.efi` is marked trusted, F2 works even when
the Limine NVRAM entry is present. Omarchy updates replace the
binary at the same path, so the whitelist stays valid.

Omarchy does **not** re-create the NVRAM entry on `omarchy-update`
or `pacman -Syu`. If `omarchy-reinstall` does re-create it, F2
still works because the binary is already whitelisted.

This fix has no `install.sh`/`uninstall.sh` because it installs no
persistent payload. The firmware whitelist is manual BIOS work that
cannot be scripted from Linux.

## Secure Boot

Omarchy supports Secure Boot via `sbctl` custom keys (see
[Omarchy Dual-Boot Secure Boot Setup](https://github.com/omacom/omarchy/discussions/2296)).
This fix and Secure Boot are **complementary** — they use different
mechanisms and do not conflict:

| Mechanism | Purpose | Type | Survives binary update? |
| --- | --- | --- | --- |
| This fix (firmware whitelist) | Fixes F2 hang on Acer Insyde | Path-based | ✅ Yes |
| Omarchy Secure Boot (`sbctl`) | Boot security | Signature-based | ❌ Needs re-sign |

**Order of operations on this Acer:**

1. Delete the Limine NVRAM entry (use `restore-bios-access.sh`).
2. Enter BIOS Setup (F2 now works).
3. Set a **supervisor password** (required to unlock Secure Boot
   options on Acer).
4. Use **"Select an UEFI file as trusted for executing"** → select
   `\EFI\limine\limine_x64.efi` (fixes the F2 hang permanently).
5. Follow the Omarchy Secure Boot guide (`sbctl create-keys`,
   `sbctl enroll-keys -m`, sign binaries, enable Secure Boot).
6. Re-add the Limine NVRAM entry with `efibootmgr --create`.

After step 4, F2 works even with the Limine entry present. After
step 5, Secure Boot is active. Both survive Omarchy updates — the
whitelist because it is path-based, Secure Boot because Omarchy
re-signs binaries on `limine-mkinitcpio` (if configured).

**Note:** Limine's default config does not verify kernel hashes. For
full Secure Boot protection, enroll a BLAKE2B config checksum with
`limine enroll-config` (see
[Arch Wiki: Limine](https://wiki.archlinux.org/title/Limine#Configuration)).
Without this, an attacker with ESP write access can swap the kernel.
