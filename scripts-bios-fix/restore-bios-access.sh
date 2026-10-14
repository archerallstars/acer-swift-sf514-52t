#!/usr/bin/env bash
# Interactive recovery for the Acer Insyde F2 BIOS Setup hang caused
# by Limine EFI entries in NVRAM. Lists NVRAM boot entries, highlights
# Limine entries only, and deletes the selected entry after explicit
# per-entry confirmation. Other bootloaders (Fedora GRUB2,
# GRUB, etc.) are never touched. Never deletes without a typed "yes".
#
# Run on the host, as root. From distrobox the script re-execs with
# distrobox-host-exec sudo.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Tools ---
efibootmgr_executable_name="efibootmgr"

# --- Limine entry name fragments (case-insensitive match against efibootmgr labels) ---
# Only Limine entries are offered for deletion. Fedora GRUB2,
# GRUB, and other bootloaders are left alone.
limine_entry_name_fragments=("limine")
windows_entry_name_fragment="Windows Boot Manager"

# --- Confirmation prompt ---
confirmation_required_text="yes"

# --- Post-recovery instructions (printed after a successful delete) ---
bootloader_label_for_recreate="Limine"
bootloader_esp_disk="/dev/nvme0n1"
bootloader_esp_partition="1"
bootloader_esp_loader='\EFI\limine\limine_x64.efi'

# --- Log prefix ---
restore_log_name="sf514-bios-restore"

# =============================================================================
# LOGGER
# =============================================================================

# Print an error line to stderr.
log_error() {
	local log_message="$1"
	echo "${restore_log_name}: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "${restore_log_name}: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# List NVRAM entries, prompt for deletion of Limine entries,
# and print post-recovery BIOS Setup steps. Exits 0 on success.
main() {
	require_root
	path_reexec_on_host_if_container "$@"
	host_require_efibootmgr
	entries_list_all
	entries_prompt_delete_limine
	instructions_print_post_recovery
}

# =============================================================================
# HOST / PATH HELPERS
# =============================================================================

# Re-exec on the host with sudo when running inside distrobox.
# Passes all original arguments through. Exits the child's status.
path_reexec_on_host_if_container() {
	if [[ -n "${DISTROBOX_ENTER_PATH:-}" ]] || [[ -f "/run/.containerenv" ]]; then
		# Inside a container: re-exec on the host as root.
		exec distrobox-host-exec sudo "$0" "$@"
	else
		# Already on the host: nothing to re-exec.
		:
	fi
}

# Verify the script is running as root. Exits 1 when not root.
require_root() {
	if [[ "${EUID}" -ne 0 ]]; then
		# Not root; NVRAM writes need elevated privileges.
		log_error "must run as root (sudo). NVRAM writes need elevated privileges."
		exit 1
	else
		# Running as root; proceed.
		:
	fi
}

# Verify efibootmgr is available. Exits 1 when missing.
host_require_efibootmgr() {
	if command -v "${efibootmgr_executable_name}" >/dev/null 2>&1; then
		# efibootmgr is on PATH; proceed.
		:
	else
		# efibootmgr is not installed; cannot manage NVRAM entries.
		log_error "efibootmgr not found on PATH. Install it and retry."
		exit 1
	fi
}

# =============================================================================
# ENTRY LISTING AND DELETION
# =============================================================================

# Print all NVRAM boot entries with their Boot#### numbers and labels.
entries_list_all() {
	log_info "current NVRAM boot entries:"
	log_info "----"
	"${efibootmgr_executable_name}" || true
	log_info "----"
}

# Prompt the user to delete each Limine entry. Asks for a typed
# "yes" before each efibootmgr --delete-bootnum call. Never deletes
# without confirmation. Never touches other bootloaders (Fedora
# GRUB2, systemd-boot) or the Windows Boot Manager entry.
entries_prompt_delete_limine() {
	local entry_line
	local entry_boot_number
	local entry_label
	local matched_fragment
	local current_fragment
	local deletion_count=0

	# Iterate over Boot#### lines and offer to delete Limine entries.
	while IFS= read -r entry_line; do
		if [[ "${entry_line}" =~ ^Boot([0-9A-Fa-f]{4}) ]]; then
			entry_boot_number="${BASH_REMATCH[1]}"
			# Extract the label after the optional active marker.
			entry_label="${entry_line#Boot${entry_boot_number}}"
			entry_label="${entry_label#\*}"
			matched_fragment=""
			for current_fragment in "${limine_entry_name_fragments[@]}"; do
				if echo "${entry_label}" | grep -qi "${current_fragment}"; then
					# Found a Limine-related fragment in this entry label.
					matched_fragment="${current_fragment}"
					break
				else
					# This fragment did not match; try the next one.
					:
				fi
			done
			if [[ -n "${matched_fragment}" ]]; then
				# Limine entry found; offer to delete it.
				entry_offer_delete "${entry_boot_number}" "${entry_label}"
				deletion_count=$((deletion_count + 1))
			else
				# Not a Limine entry; leave it alone.
				:
			fi
		else
			# Not a Boot#### line; skip.
			:
		fi
	done < <("${efibootmgr_executable_name}" 2>/dev/null || true)

	if [[ "${deletion_count}" -eq 0 ]]; then
		# No Limine entries found; nothing to delete.
		log_info "no Limine EFI entries found in NVRAM. Nothing to delete."
	else
		# At least one Limine entry was offered for deletion.
		log_info "processed ${deletion_count} Limine entry/entries."
	fi
}

# Offer to delete one NVRAM entry. Asks for typed confirmation.
# Inputs: entry_boot_number (4 hex digits), entry_label (human text).
entry_offer_delete() {
	local entry_boot_number="$1"
	local entry_label="$2"
	local confirmation_input

	log_info "----"
	log_info "candidate: Boot${entry_boot_number}  ${entry_label}"
	log_info "deleting this entry restores F2 BIOS Setup access on Acer Insyde firmware."
	printf "type '%s' to delete Boot%s, anything else to skip: " "${confirmation_required_text}" "${entry_boot_number}"
	read -r confirmation_input

	if [[ "${confirmation_input}" == "${confirmation_required_text}" ]]; then
		# User confirmed deletion; remove the NVRAM entry.
		if "${efibootmgr_executable_name}" --delete-bootnum --bootnum "${entry_boot_number}"; then
			# Deletion succeeded.
			log_info "deleted Boot${entry_boot_number}."
		else
			# Deletion failed; report and continue with other entries.
			log_error "failed to delete Boot${entry_boot_number}."
		fi
	else
		# User did not confirm; skip this entry.
		log_info "skipped Boot${entry_boot_number}."
	fi
}

# =============================================================================
# POST-RECOVERY INSTRUCTIONS
# =============================================================================

# Print the BIOS Setup steps to run after F2 works again, and the
# efibootmgr command to re-create the bootloader entry.
instructions_print_post_recovery() {
	log_info "===="
	log_info "post-recovery steps (run these after F2 enters BIOS Setup again):"
	log_info "  1. set a supervisor password (required to unlock Secure Boot options on Acer)"
	log_info "  2. enable Secure Boot"
	log_info "  3. 'Select an UEFI file as trusted for executing' -> ${bootloader_esp_loader}"
	log_info "  4. disable Secure Boot again (if you do not want it)"
	log_info "  5. re-add the bootloader entry:"
	log_info "     sudo efibootmgr --create \\"
	log_info "       --disk ${bootloader_esp_disk} --part ${bootloader_esp_partition} \\"
	log_info "       --label '${bootloader_label_for_recreate}' \\"
	log_info "       --loader '${bootloader_esp_loader}'"
	log_info "===="
	log_info "tip: press 'S' in the Limine menu to enter Firmware Setup without F2."
}

# =============================================================================
# SCRIPT ENTRY
# =============================================================================

main "$@"
