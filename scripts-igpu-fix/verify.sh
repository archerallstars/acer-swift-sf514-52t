#!/usr/bin/env bash
# Check that i915 display C-states are disabled on this laptop and
# that Panel Self Refresh is at the kernel default (no
# i915.enable_psr=0). Plumbing needs no root. Staged bootloader
# kargs are checked when rpm-ostree or grubby can be read.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Kernel argument tokens ---
display_cstate_disable_kernel_argument="i915.enable_dc=0"
panel_self_refresh_disable_kernel_argument="i915.enable_psr=0"

# --- Live vs staged kargs ---
proc_cmdline_path="/proc/cmdline"
ostree_root_directory="/ostree"

# --- Bootloader backends (immutable ostree vs mutable Fedora) ---
bootloader_backend_rpm_ostree_name="rpm-ostree"
bootloader_backend_grubby_name="grubby"
rpm_ostree_executable_name="rpm-ostree"
grubby_executable_name="grubby"

# --- Log prefix ---
verify_log_name="sf514-igpu-verify"

# =============================================================================
# LOGGER AND CHECK COUNTERS
# =============================================================================

check_pass_count=0
check_fail_count=0
check_skip_count=0
bootloader_backend_name=""
live_kernel_arguments_text=""
staged_kernel_arguments_text=""
staged_kernel_arguments_readable=0

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

# Run live and staged kernel-argument checks. Exits 0 only when
# every required check passed.
main() {
	path_reexec_on_host_if_container "$@"
	host_detect_bootloader_backend
	host_read_live_kernel_arguments
	host_try_read_staged_kernel_arguments
	check_live_display_cstate_disabled
	check_live_panel_self_refresh_default
	check_staged_display_cstate_disabled
	check_staged_panel_self_refresh_default
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
# FILE I/O QUEUE
# =============================================================================

# Parallel arrays for pending local filesystem jobs. Kind read-text
# loads the source path into file_io_last_read_text.
file_io_job_source_paths=()
file_io_job_destination_paths=()
file_io_job_kinds=()
file_io_last_read_text=""

# Run one queued filesystem job.
# read-text stores the file contents in file_io_last_read_text.
# Inputs: source_path, destination_path, job_kind.
file_io_queue_apply_one_job() {
	local source_path="$1"
	local destination_path="$2"
	local job_kind="$3"
	if [[ "${job_kind}" == "read-text" ]]; then
		if [[ "${source_path}" != "${destination_path}" ]]; then
			log_error "read-text source and destination must be the same path"
			exit 1
		elif [[ -r "${source_path}" ]]; then
			file_io_last_read_text="$(<"${source_path}")"
		else
			log_error "Cannot read ${source_path}"
			exit 1
		fi
	else
		log_error "Unknown file I/O job kind ${job_kind}"
		exit 1
	fi
}

# Apply every queued job in order, then clear the arrays.
file_io_queue_drain() {
	local job_index
	if [[ "${#file_io_job_kinds[@]}" -eq 0 ]]; then
		return 0  # nothing queued
	else
		for job_index in "${!file_io_job_kinds[@]}"; do
			file_io_queue_apply_one_job \
				"${file_io_job_source_paths[job_index]}" \
				"${file_io_job_destination_paths[job_index]}" \
				"${file_io_job_kinds[job_index]}"
		done
		file_io_job_source_paths=()
		file_io_job_destination_paths=()
		file_io_job_kinds=()
		return 0  # queue emptied
	fi
}

# Append one filesystem job.
# Inputs: source_path, destination_path, job_kind.
file_io_queue_enqueue() {
	local source_path="$1"
	local destination_path="$2"
	local job_kind="$3"
	file_io_job_source_paths+=("${source_path}")
	file_io_job_destination_paths+=("${destination_path}")
	file_io_job_kinds+=("${job_kind}")
}

# =============================================================================
# KERNEL ARGUMENT TOKENS
# =============================================================================

# Return 0 when kernel_argument_text contains kernel_argument_token
# as a whole space-separated word.
# Inputs: kernel_argument_text, kernel_argument_token.
karg_text_contains_token() {
	local kernel_argument_text="$1"
	local kernel_argument_token="$2"
	local padded_kernel_argument_text=" ${kernel_argument_text} "
	if [[ "${padded_kernel_argument_text}" == *" ${kernel_argument_token} "* ]]; then
		return 0  # token is present as a whole word
	else
		return 1  # token is absent
	fi
}

# =============================================================================
# BOOTLOADER (rpm-ostree or grubby)
# =============================================================================

# Choose rpm-ostree when /ostree exists and the tool is installed,
# otherwise grubby. Exits 1 when neither backend is available.
# Sets bootloader_backend_name.
host_detect_bootloader_backend() {
	if [[ -d "${ostree_root_directory}" ]] && command -v "${rpm_ostree_executable_name}" >/dev/null 2>&1; then
		bootloader_backend_name="${bootloader_backend_rpm_ostree_name}"
		log_info "Bootloader backend: ${bootloader_backend_name} (immutable ostree)."
		return 0  # ostree host
	else
		if command -v "${grubby_executable_name}" >/dev/null 2>&1; then
			bootloader_backend_name="${bootloader_backend_grubby_name}"
			log_info "Bootloader backend: ${bootloader_backend_name} (mutable Fedora)."
			return 0  # grubby host
		else
			log_error "Need ${rpm_ostree_executable_name} on ostree or ${grubby_executable_name} on a mutable Fedora root."
			exit 1
		fi
	fi
}

# Read DEFAULT kernel args from grubby --info. Sets
# staged_kernel_arguments_text from the first args= or options= line.
host_read_grubby_default_arguments() {
	local grubby_info_text
	local info_line
	local parsed_arguments=""
	if grubby_info_text="$("${grubby_executable_name}" --info=DEFAULT)"; then
		:
	else
		return 1  # grubby --info=DEFAULT failed
	fi
	while IFS= read -r info_line; do
		if [[ "${info_line}" == args=* ]]; then
			if [[ -z "${parsed_arguments}" ]]; then
				parsed_arguments="${info_line#args=}"
			else
				:
			fi
		elif [[ "${info_line}" == options=* ]]; then
			if [[ -z "${parsed_arguments}" ]]; then
				parsed_arguments="${info_line#options=}"
			else
				:
			fi
		else
			:
		fi
	done <<< "${grubby_info_text}"
	parsed_arguments="${parsed_arguments#\"}"
	parsed_arguments="${parsed_arguments%\"}"
	staged_kernel_arguments_text="${parsed_arguments}"
	return 0  # DEFAULT args parsed
}

# Load /proc/cmdline into live_kernel_arguments_text through the
# file I/O queue.
host_read_live_kernel_arguments() {
	file_io_queue_enqueue \
		"${proc_cmdline_path}" \
		"${proc_cmdline_path}" \
		"read-text"
	file_io_queue_drain
	live_kernel_arguments_text="${file_io_last_read_text}"
}

# Load staged kernel arguments when the bootloader tool is readable
# without root. Sets staged_kernel_arguments_readable to 1 on
# success. Does not exit when the tool fails (verify is unprivileged).
host_try_read_staged_kernel_arguments() {
	if [[ "${bootloader_backend_name}" == "${bootloader_backend_rpm_ostree_name}" ]]; then
		if staged_kernel_arguments_text="$("${rpm_ostree_executable_name}" kargs 2>/dev/null)"; then
			staged_kernel_arguments_readable=1
			return 0  # rpm-ostree kargs listed
		else
			staged_kernel_arguments_readable=0
			staged_kernel_arguments_text=""
			return 0  # recorded as unreadable
		fi
	else
		if host_read_grubby_default_arguments 2>/dev/null; then
			staged_kernel_arguments_readable=1
			return 0  # grubby DEFAULT parsed
		else
			staged_kernel_arguments_readable=0
			staged_kernel_arguments_text=""
			return 0  # recorded as unreadable
		fi
	fi
}

# =============================================================================
# CHECKS
# =============================================================================

# Require live /proc/cmdline to contain i915.enable_dc=0.
check_live_display_cstate_disabled() {
	if karg_text_contains_token \
		"${live_kernel_arguments_text}" \
		"${display_cstate_disable_kernel_argument}"; then
		report_pass "live-dc" "${proc_cmdline_path} has ${display_cstate_disable_kernel_argument}"
		return 0  # live DC disabled
	else
		report_fail "live-dc" "${proc_cmdline_path} lacks ${display_cstate_disable_kernel_argument} (reboot after install.sh if staged kargs already have it)"
		return 0  # recorded as fail
	fi
}

# Require live /proc/cmdline to omit i915.enable_psr=0.
check_live_panel_self_refresh_default() {
	if karg_text_contains_token \
		"${live_kernel_arguments_text}" \
		"${panel_self_refresh_disable_kernel_argument}"; then
		report_fail "live-psr" "${proc_cmdline_path} still has ${panel_self_refresh_disable_kernel_argument}; install.sh drops it, then reboot"
		return 0  # recorded as fail
	else
		report_pass "live-psr" "${proc_cmdline_path} omits ${panel_self_refresh_disable_kernel_argument}"
		return 0  # live PSR at kernel default
	fi
}

# Require staged bootloader kargs to contain i915.enable_dc=0.
# Skip when the bootloader tool is unreadable.
check_staged_display_cstate_disabled() {
	if [[ "${staged_kernel_arguments_readable}" -ne 1 ]]; then
		report_skip "staged-dc" "cannot read ${bootloader_backend_name} kargs as this user"
		return 0  # skipped
	elif karg_text_contains_token \
		"${staged_kernel_arguments_text}" \
		"${display_cstate_disable_kernel_argument}"; then
		report_pass "staged-dc" "${bootloader_backend_name} has ${display_cstate_disable_kernel_argument}"
		return 0  # staged DC disabled
	else
		report_fail "staged-dc" "${bootloader_backend_name} lacks ${display_cstate_disable_kernel_argument}; run install.sh"
		return 0  # recorded as fail
	fi
}

# Require staged bootloader kargs to omit i915.enable_psr=0.
# Skip when the bootloader tool is unreadable.
check_staged_panel_self_refresh_default() {
	if [[ "${staged_kernel_arguments_readable}" -ne 1 ]]; then
		report_skip "staged-psr" "cannot read ${bootloader_backend_name} kargs as this user"
		return 0  # skipped
	elif karg_text_contains_token \
		"${staged_kernel_arguments_text}" \
		"${panel_self_refresh_disable_kernel_argument}"; then
		report_fail "staged-psr" "${bootloader_backend_name} still has ${panel_self_refresh_disable_kernel_argument}; run install.sh"
		return 0  # recorded as fail
	else
		report_pass "staged-psr" "${bootloader_backend_name} omits ${panel_self_refresh_disable_kernel_argument}"
		return 0  # staged PSR at kernel default
	fi
}

# =============================================================================
# PATH HELPERS
# =============================================================================

# When started inside distrobox, re-exec on the host as the same user
# so /proc/cmdline and rpm-ostree kargs are the host's.
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

main "$@"
