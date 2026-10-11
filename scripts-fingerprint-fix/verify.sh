#!/usr/bin/env bash
# Check that the EgisTec 0570 overlay is loaded by fprintd on this laptop.
# Plumbing checks need no finger. Pass --live to enroll (if empty) and
# verify once; that section waits for a finger on the pad.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

expected_usb_vendor_product="1c7a:0570"
overlay_library_path_on_host="/var/usrlocal/lib64/libfprint-2.so.2"
overlay_library_path_from_container="/run/host/var/usrlocal/lib64/libfprint-2.so.2"
overlay_library_real_path_on_host="/var/usrlocal/lib64/libfprint-2.so.2.0.0"
overlay_dropin_path_on_host="/etc/systemd/system/fprintd.service.d/sf514-egis0570.conf"
overlay_dropin_path_from_container="/run/host/etc/systemd/system/fprintd.service.d/sf514-egis0570.conf"
overlay_udev_path_on_host="/etc/udev/rules.d/70-sf514-egis0570.rules"
overlay_udev_path_from_container="/run/host/etc/udev/rules.d/70-sf514-egis0570.rules"
expected_selinux_type="lib_t"
expected_selinux_unit_file_type="systemd_unit_file_t"
expected_device_name_fragment="0570"
fprintd_unit_name="fprintd.service"
maps_overlay_fragment="/var/usrlocal/lib64/libfprint-2.so"

# =============================================================================
# LOGGER AND CHECK COUNTERS
# =============================================================================

check_pass_count=0
check_fail_count=0
check_skip_count=0
live_check_requested=0

# Print an error line to stderr.
log_error() {
	local log_message="$1"
	echo "sf514-fp-verify: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "sf514-fp-verify: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Run plumbing checks, and live enroll/verify when --live is passed.
# Exits 0 only when every required check passed.
main() {
	path_parse_command_line "$@"
	path_reexec_on_host_if_container "$@"
	path_resolve_overlay_paths
	check_usb_device_present
	check_overlay_library_present
	check_dropin_present
	check_udev_rule_present
	check_selinux_dropin_type
	check_selinux_library_type
	check_fprintd_lists_egis
	check_fprintd_maps_overlay
	if [[ "${live_check_requested}" -eq 1 ]]; then
		check_live_enroll_and_verify
	else
		report_skip "live" "pass --live and hold a finger on the pad to test enroll/verify"
	fi
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

# Print totals and exit 1 when any required check failed.
report_summarize() {
	log_info "Summary: ${check_pass_count} passed, ${check_fail_count} failed, ${check_skip_count} skipped"
	if [[ "${check_fail_count}" -ne 0 ]]; then
		exit 1
	else
		exit 0  # every required check passed
	fi
}

# =============================================================================
# CHECKS
# =============================================================================

# Require the fprintd drop-in that sets LD_LIBRARY_PATH.
check_dropin_present() {
	if [[ -n "${resolved_dropin_path}" && -f "${resolved_dropin_path}" ]]; then
		report_pass "drop-in" "${resolved_dropin_path}"
		return 0  # drop-in is installed
	else
		report_fail "drop-in" "missing ${overlay_dropin_path_on_host}"
		return 0  # recorded as fail
	fi
}

# Require fprintd-list to name the Egis 0570 pad.
check_fprintd_lists_egis() {
	local fprintd_list_path
	local list_text
	if fprintd_list_path="$(path_find_executable fprintd-list)"; then
		:
	else
		report_fail "fprintd-list" "fprintd-list not installed"
		return 0  # recorded as fail
	fi
	if list_text="$("${fprintd_list_path}" "$(id -un)" 2>&1)"; then
		:
	else
		report_fail "fprintd-list" "command failed: ${list_text}"
		return 0  # recorded as fail
	fi
	if [[ "${list_text}" == *"${expected_device_name_fragment}"* ]]; then
		report_pass "fprintd-list" "saw Egis 0570 for $(id -un)"
		return 0  # device enumerated
	else
		report_fail "fprintd-list" "output did not mention ${expected_device_name_fragment}: ${list_text}"
		return 0  # recorded as fail
	fi
}

# After fprintd-list, require /proc/$(pidof fprintd)/maps to include the overlay.
check_fprintd_maps_overlay() {
	local fprintd_pid
	local maps_path
	local maps_text
	fprintd_pid="$(pidof fprintd 2>/dev/null || true)"
	if [[ -z "${fprintd_pid}" ]]; then
		report_fail "fprintd-maps" "fprintd is not running (fprintd-list should have started it)"
		return 0  # recorded as fail
	else
		maps_path="/proc/${fprintd_pid}/maps"
		if [[ -r "${maps_path}" ]]; then
			maps_text="$(<"${maps_path}")"
			if [[ "${maps_text}" == *"${maps_overlay_fragment}"* ]]; then
				report_pass "fprintd-maps" "pid ${fprintd_pid} maps ${maps_overlay_fragment}"
				return 0  # overlay library is loaded
			else
				report_fail "fprintd-maps" "pid ${fprintd_pid} does not map ${maps_overlay_fragment}; check the drop-in and SELinux"
				return 0  # recorded as fail
			fi
		else
			report_fail "fprintd-maps" "cannot read ${maps_path}"
			return 0  # recorded as fail
		fi
	fi
}

# Optional: enroll if this user has no prints, then verify once.
check_live_enroll_and_verify() {
	local fprintd_enroll_path
	local fprintd_verify_path
	local fprintd_list_path
	local list_text
	if fprintd_enroll_path="$(path_find_executable fprintd-enroll)"; then
		:
	else
		report_fail "live-enroll" "fprintd-enroll not installed"
		return 0  # recorded as fail
	fi
	if fprintd_verify_path="$(path_find_executable fprintd-verify)"; then
		:
	else
		report_fail "live-verify" "fprintd-verify not installed"
		return 0  # recorded as fail
	fi
	if fprintd_list_path="$(path_find_executable fprintd-list)"; then
		list_text="$("${fprintd_list_path}" "$(id -un)" 2>&1 || true)"
	else
		list_text=""
	fi
	log_info "Hold a finger on the pad. Keep it still for about a second per stage. Lift between stages."
	if [[ "${list_text}" == *"fingerprints:"* && "${list_text}" != *"- "* ]]; then
		if "${fprintd_enroll_path}"; then
			report_pass "live-enroll" "fprintd-enroll completed"
		else
			report_fail "live-enroll" "fprintd-enroll failed"
			return 0  # recorded as fail
		fi
	else
		log_info "NOTE  Prints already enrolled for $(id -un); skipping enroll"
		report_skip "live-enroll" "already enrolled"
	fi
	if "${fprintd_verify_path}"; then
		report_pass "live-verify" "fprintd-verify accepted the finger"
		return 0  # live match succeeded
	else
		report_fail "live-verify" "fprintd-verify failed"
		return 0  # recorded as fail
	fi
}

# Require the overlay .so under /var/usrlocal/lib64.
check_overlay_library_present() {
	if [[ -n "${resolved_library_path}" && -e "${resolved_library_path}" ]]; then
		report_pass "overlay-library" "${resolved_library_path}"
		return 0  # library is in place
	else
		report_fail "overlay-library" "missing ${overlay_library_path_on_host} (run install.sh)"
		return 0  # recorded as fail
	fi
}

# Require systemd_unit_file_t on the fprintd drop-in when SELinux is on.
# user_home_t from a homedir copy means PID 1 cannot parse Environment=.
check_selinux_dropin_type() {
	local dropin_path="${resolved_dropin_path}"
	local selinux_type
	if [[ ! -e /sys/fs/selinux/enforce ]]; then
		report_skip "selinux-drop-in" "SELinux is not enabled on this host"
		return 0  # Debian/Ubuntu/Arch typically have no SELinux
	else
		:
	fi
	if [[ -z "${dropin_path}" || ! -f "${dropin_path}" ]]; then
		report_fail "selinux-drop-in" "drop-in missing, cannot check type"
		return 0  # recorded as fail
	else
		:
	fi
	if command -v getenforce >/dev/null 2>&1; then
		if [[ "$(getenforce 2>/dev/null || true)" == "Disabled" ]]; then
			report_skip "selinux-drop-in" "SELinux is disabled"
			return 0  # nothing to check
		else
			:
		fi
	else
		:
	fi
	if command -v ls >/dev/null 2>&1; then
		selinux_type="$(ls -Z "${dropin_path}" 2>/dev/null | awk '{print $1}' | awk -F: '{print $3}')"
		if [[ "${selinux_type}" == "${expected_selinux_unit_file_type}" ]]; then
			report_pass "selinux-drop-in" "${dropin_path} is ${expected_selinux_unit_file_type}"
			return 0  # systemd can read the drop-in
		else
			report_fail "selinux-drop-in" "${dropin_path} type is '${selinux_type}', expected ${expected_selinux_unit_file_type}"
			return 0  # recorded as fail
		fi
	else
		report_skip "selinux-drop-in" "cannot read file context"
		return 0  # optional when ls -Z is unavailable
	fi
}

# Require SELinux type lib_t on the overlay .so when SELinux is enforcing.
check_selinux_library_type() {
	local library_path="${overlay_library_real_path_on_host}"
	local selinux_type
	if [[ ! -e /sys/fs/selinux/enforce ]]; then
		report_skip "selinux" "SELinux is not enabled on this host"
		return 0  # Debian/Ubuntu/Arch typically have no SELinux
	else
		:
	fi
	if [[ ! -e "${library_path}" ]]; then
		if [[ -e "/run/host${library_path}" ]]; then
			library_path="/run/host${library_path}"
		else
			report_fail "selinux" "overlay library missing, cannot check type"
			return 0  # recorded as fail
		fi
	else
		:
	fi
	if command -v getenforce >/dev/null 2>&1; then
		if [[ "$(getenforce 2>/dev/null || true)" == "Disabled" ]]; then
			report_skip "selinux" "SELinux is disabled"
			return 0  # nothing to check
		else
			:
		fi
	else
		:
	fi
	if command -v ls >/dev/null 2>&1; then
		selinux_type="$(ls -Z "${library_path}" 2>/dev/null | awk '{print $1}' | awk -F: '{print $3}')"
		if [[ "${selinux_type}" == "${expected_selinux_type}" ]]; then
			report_pass "selinux" "${library_path} is ${expected_selinux_type}"
			return 0  # fprintd can mmap the overlay
		else
			report_fail "selinux" "${library_path} type is '${selinux_type}', expected ${expected_selinux_type}"
			return 0  # recorded as fail
		fi
	else
		report_skip "selinux" "cannot read file context"
		return 0  # optional when ls -Z is unavailable
	fi
}

# Require the udev rule that grants seat access for the capture tool.
check_udev_rule_present() {
	if [[ -f "${overlay_udev_path_on_host}" ]]; then
		report_pass "udev" "${overlay_udev_path_on_host}"
		return 0  # rule installed
	elif [[ -f "${overlay_udev_path_from_container}" ]]; then
		report_pass "udev" "${overlay_udev_path_from_container}"
		return 0  # rule visible from the container
	else
		report_fail "udev" "missing ${overlay_udev_path_on_host}"
		return 0  # recorded as fail
	fi
}

# Require USB 1c7a:0570 on the bus.
check_usb_device_present() {
	local lsusb_path
	local lsusb_text
	if lsusb_path="$(path_find_executable lsusb)"; then
		:
	else
		report_fail "usb" "lsusb not installed"
		return 0  # recorded as fail
	fi
	if lsusb_text="$("${lsusb_path}" -d "${expected_usb_vendor_product}" 2>&1)"; then
		if [[ "${lsusb_text}" == *"${expected_usb_vendor_product}"* ]]; then
			report_pass "usb" "${lsusb_text}"
			return 0  # pad is on the bus
		else
			report_fail "usb" "lsusb -d ${expected_usb_vendor_product} returned: ${lsusb_text}"
			return 0  # recorded as fail
		fi
	else
		report_fail "usb" "USB ${expected_usb_vendor_product} not present"
		return 0  # recorded as fail
	fi
}

# =============================================================================
# PATH HELPERS
# =============================================================================

# Print the first executable named executable_name on PATH, /usr/bin,
# or /run/host/usr/bin. Returns 1 when none exist.
# Inputs: executable_name. Output: absolute or PATH name on stdout.
path_find_executable() {
	local executable_name="$1"
	local candidate_path
	if command -v "${executable_name}" >/dev/null 2>&1; then
		command -v "${executable_name}"
		return 0  # found on PATH
	else
		for candidate_path in \
			"/usr/bin/${executable_name}" \
			"/run/host/usr/bin/${executable_name}"
		do
			if [[ -x "${candidate_path}" ]]; then
				echo "${candidate_path}"
				return 0  # found a host or local binary
			else
				:
			fi
		done
		return 1  # executable_name is not installed
	fi
}

# Accept --live to run enroll/verify. Unknown flags fail.
path_parse_command_line() {
	local argument
	for argument in "$@"; do
		if [[ "${argument}" == "--live" ]]; then
			live_check_requested=1
		elif [[ "${argument}" == "--help" || "${argument}" == "-h" ]]; then
			log_info "Usage: $0 [--live]"
			exit 0
		else
			log_error "Unknown argument ${argument} (try --live)"
			exit 1
		fi
	done
}

# When started inside distrobox, re-exec on the host as the same user
# so fprintd-list and /proc maps see the host daemon.
path_reexec_on_host_if_container() {
	if [[ -f /run/.containerenv || -f /.dockerenv ]]; then
		if command -v distrobox-host-exec >/dev/null 2>&1; then
			local script_absolute_path
			script_absolute_path="$(readlink -f "${BASH_SOURCE[0]}")"
			log_info "Re-running on the host via distrobox-host-exec"
			exec distrobox-host-exec bash "${script_absolute_path}" "$@"
		else
			log_error "Run verify.sh on the host, not inside a container."
			exit 1
		fi
	else
		return 0  # already on the host
	fi
}

# Set resolved_library_path and resolved_dropin_path to host or
# container-visible locations.
path_resolve_overlay_paths() {
	if [[ -e "${overlay_library_path_on_host}" ]]; then
		resolved_library_path="${overlay_library_path_on_host}"
	elif [[ -e "${overlay_library_path_from_container}" ]]; then
		resolved_library_path="${overlay_library_path_from_container}"
	else
		resolved_library_path=""
	fi
	if [[ -f "${overlay_dropin_path_on_host}" ]]; then
		resolved_dropin_path="${overlay_dropin_path_on_host}"
	elif [[ -f "${overlay_dropin_path_from_container}" ]]; then
		resolved_dropin_path="${overlay_dropin_path_from_container}"
	else
		resolved_dropin_path=""
	fi
}

resolved_library_path=""
resolved_dropin_path=""

main "$@"
