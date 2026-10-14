#!/usr/bin/env bash
# Check NVRAM boot-entry status on this Acer Insyde laptop and warn
# when the F2 BIOS Setup hang risk is present (Limine entries).
# Also checks whether the Windows Boot Manager entry is intact
# (recommended on Acer). Needs no root. Pass nothing.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Tools ---
efibootmgr_executable_name="efibootmgr"

# --- Limine entry name fragments (case-insensitive match against efibootmgr labels) ---
# Only Limine entries trigger the F2 hang risk warning. Fedora
# GRUB2, systemd-boot, and other bootloaders are ignored.
limine_entry_name_fragments=("limine")
windows_entry_name_fragment="Windows Boot Manager"

# --- Windows Boot Manager path on the ESP ---
windows_boot_manager_relative_path="EFI/Microsoft/Boot/bootmgfw.efi"
esp_candidate_mount_points=("/boot" "/boot/efi" "/efi")

# --- Limine escape hatch reminder ---
limine_firmware_setup_key="S"

# --- Log prefix ---
verify_log_name="sf514-bios-verify"

# =============================================================================
# LOGGER AND CHECK COUNTERS
# =============================================================================

check_pass_count=0
check_fail_count=0
check_skip_count=0
efibootmgr_output_text=""
limine_entry_count=0
windows_entry_present=0

# Print an error line to stderr.
log_error() {
	local log_message="$1"
	echo "${verify_log_name}: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "${verify_log_name}: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Run NVRAM entry checks and print the Limine escape-hatch reminder.
# Exits 0 when no F2-hang risk is present, 1 otherwise.
main() {
	path_reexec_on_host_if_container "$@"
	host_read_efibootmgr_output
	check_limine_entries_present
	check_windows_boot_manager_entry_present
	check_windows_boot_manager_file_present
	report_limine_escape_hatch
	report_summarize
}

# =============================================================================
# REPORT HELPERS
# =============================================================================

# Record a failed check. Inputs: check_name, check_detail.
report_fail() {
	local check_name="$1"
	local check_detail="$2"
	check_fail_count=$((check_fail_count + 1))
	log_error "FAIL  ${check_name}: ${check_detail}"
}

# Record a passed check. Inputs: check_name, check_detail.
report_pass() {
	local check_name="$1"
	local check_detail="$2"
	check_pass_count=$((check_pass_count + 1))
	log_info "PASS  ${check_name}: ${check_detail}"
}

# Record a skipped check. Inputs: check_name, check_detail.
report_skip() {
	local check_name="$1"
	local check_detail="$2"
	check_skip_count=$((check_skip_count + 1))
	log_info "SKIP  ${check_name}: ${check_detail}"
}

# Print the Limine Firmware Setup escape-hatch reminder (always shown).
report_limine_escape_hatch() {
	log_info "INFO  limine-escape-hatch: press '${limine_firmware_setup_key}' in the Limine menu to enter Firmware Setup"
}

# Print totals and exit 1 when any required check failed.
report_summarize() {
	log_info "----"
	log_info "pass=${check_pass_count} fail=${check_fail_count} skip=${check_skip_count}"
	if [[ "${check_fail_count}" -gt 0 ]]; then
		# F2-hang risk is present or Windows Boot Manager is missing.
		return 1
	else
		# All required checks passed; no F2-hang risk detected.
		return 0
	fi
}

# =============================================================================
# HOST / PATH HELPERS
# =============================================================================

# Re-exec on the host when running inside distrobox. Passes all
# original arguments through. Exits the child's status.
path_reexec_on_host_if_container() {
	if [[ -n "${DISTROBOX_ENTER_PATH:-}" ]] || [[ -f "/run/.containerenv" ]]; then
		# Inside a container: re-exec on the host as the same user.
		exec distrobox-host-exec "$0" "$@"
	else
		# Already on the host: nothing to re-exec.
		:
	fi
}

# =============================================================================
# NVRAM CHECKS
# =============================================================================

# Read efibootmgr output into a global. Skips checks when the tool
# is missing or unreadable.
host_read_efibootmgr_output() {
	if command -v "${efibootmgr_executable_name}" >/dev/null 2>&1; then
		# efibootmgr is available; capture its output for later checks.
		efibootmgr_output_text="$("${efibootmgr_executable_name}" 2>/dev/null || true)"
	else
		# efibootmgr is not on PATH; leave the output empty.
		efibootmgr_output_text=""
	fi
}

# Count Limine boot entries in NVRAM. A non-zero count means the
# F2 hang risk is present on Acer Insyde firmware. Other bootloaders
# (Fedora GRUB2, systemd-boot) are ignored.
check_limine_entries_present() {
	if [[ -z "${efibootmgr_output_text}" ]]; then
		# No efibootmgr output; cannot evaluate NVRAM entries.
		report_skip "limine-entries" "efibootmgr not available or unreadable"
		return 0  # skipped, not a fail
	fi

	local entry_line
	local entry_label
	local matched_fragment
	local current_fragment
	limine_entry_count=0

	# Iterate over Boot#### lines and match against Limine fragments.
	while IFS= read -r entry_line; do
		if [[ "${entry_line}" =~ ^Boot[0-9A-Fa-f]{4} ]]; then
			# Extract the label after the optional active marker.
			entry_label="${entry_line#Boot????*}"
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
				# This entry is a Limine bootloader entry.
				limine_entry_count=$((limine_entry_count + 1))
				log_info "INFO  limine-entry: ${entry_line}"
			else
				# Not a Limine entry; skip silently.
				:
			fi
		else
			# Not a Boot#### line; skip.
			:
		fi
	done <<< "${efibootmgr_output_text}"

	if [[ "${limine_entry_count}" -gt 0 ]]; then
		# Limine EFI entries exist: F2 hang risk is present on Acer Insyde.
		report_fail "limine-entries" "${limine_entry_count} Limine EFI entry/entries in NVRAM (F2 hang risk on Acer Insyde)"
		return 0
	else
		# No Limine entries found: F2 hang risk is not present.
		report_pass "limine-entries" "no Limine EFI entries in NVRAM"
		return 0
	fi
}

# Check whether the Windows Boot Manager entry is present in NVRAM.
# Acer Insyde firmware special-cases this entry; keeping it is
# recommended even when Windows is not installed.
check_windows_boot_manager_entry_present() {
	if [[ -z "${efibootmgr_output_text}" ]]; then
		# No efibootmgr output; cannot evaluate NVRAM entries.
		report_skip "windows-boot-manager-entry" "efibootmgr not available or unreadable"
		return 0  # skipped, not a fail
	fi

	if echo "${efibootmgr_output_text}" | grep -qi "${windows_entry_name_fragment}"; then
		# Windows Boot Manager entry is present; recommended state.
		windows_entry_present=1
		report_pass "windows-boot-manager-entry" "present in NVRAM (recommended on Acer Insyde)"
		return 0
	else
		# Windows Boot Manager entry is missing; may worsen the F2 hang.
		windows_entry_present=0
		report_fail "windows-boot-manager-entry" "missing from NVRAM (recommended to keep on Acer Insyde)"
		return 0
	fi
}

# Check whether the Windows Boot Manager EFI file exists on the ESP.
# Keeping this file is recommended even when Windows is not installed.
check_windows_boot_manager_file_present() {
	local candidate_mount_point
	local candidate_file_path
	local file_found=0

	for candidate_mount_point in "${esp_candidate_mount_points[@]}"; do
		candidate_file_path="${candidate_mount_point}/${windows_boot_manager_relative_path}"
		if [[ -f "${candidate_file_path}" ]]; then
			# Found the Windows Boot Manager file on this ESP mount.
			file_found=1
			break
		else
			# Not on this mount point; try the next candidate.
			:
		fi
	done

	if [[ "${file_found}" -eq 1 ]]; then
		# Windows Boot Manager file exists on the ESP; recommended state.
		report_pass "windows-boot-manager-file" "found at ${candidate_file_path}"
		return 0
	else
		# Windows Boot Manager file is missing from all candidate ESPs.
		report_fail "windows-boot-manager-file" "${windows_boot_manager_relative_path} not found on any ESP mount"
		return 0
	fi
}

# =============================================================================
# SCRIPT ENTRY
# =============================================================================

main "$@"
