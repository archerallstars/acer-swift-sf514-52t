#!/usr/bin/env bash
# Remove the Acer Swift SF514-52T i915 display-C-state workaround.
# Deletes i915.enable_dc=0 from the bootloader kernel arguments when
# it is present. Does not add i915.enable_psr=0. Uses rpm-ostree
# kargs on ostree and grubby on a mutable Fedora root. Idempotent.
# Must run as root on the host.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Kernel argument tokens ---
display_cstate_disable_kernel_argument="i915.enable_dc=0"

# --- Live vs staged kargs ---
proc_cmdline_path="/proc/cmdline"
ostree_root_directory="/ostree"

# --- Bootloader backends (immutable ostree vs mutable Fedora) ---
bootloader_backend_rpm_ostree_name="rpm-ostree"
bootloader_backend_grubby_name="grubby"
rpm_ostree_executable_name="rpm-ostree"
grubby_executable_name="grubby"
grubby_update_kernel_selector="ALL"

# --- Log prefix ---
uninstall_log_name="sf514-igpu-uninstall"

# --- Filled at runtime ---
bootloader_backend_name=""
live_kernel_arguments_text=""
staged_kernel_arguments_text=""

# =============================================================================
# LOGGER
# =============================================================================

# Print an error line to stderr.
log_error() {
	local log_message="$1"
	echo "${uninstall_log_name}: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "${uninstall_log_name}: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Detect ostree vs grubby and delete i915.enable_dc=0 when it is
# staged. Exits 0 on success, 1 on failure. A reboot is required
# before the live kernel drops the karg.
main() {
	path_reexec_on_host_if_container "$@"
	path_require_root
	host_detect_bootloader_backend
	host_read_staged_kernel_arguments
	host_read_live_kernel_arguments
	host_delete_display_cstate_disable
	host_read_staged_kernel_arguments
	host_read_live_kernel_arguments
	host_report_reboot_if_live_still_has_disable
	log_info "Uninstall complete. Display C-state disable is gone from staged kernel arguments (${bootloader_backend_name})."
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

# Delete display_cstate_disable_kernel_argument when it is staged.
# Uses staged_kernel_arguments_text. Idempotent.
host_delete_display_cstate_disable() {
	if karg_text_contains_token \
		"${staged_kernel_arguments_text}" \
		"${display_cstate_disable_kernel_argument}"; then
		log_info "Removing ${display_cstate_disable_kernel_argument}."
		host_kernel_arguments_delete_token \
			"${display_cstate_disable_kernel_argument}"
		return 0  # delete finished
	else
		log_info "Display C-state disable is already absent from staged kernel arguments."
		return 0  # nothing to delete
	fi
}

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

# Delete kernel_argument_token via the detected backend.
# Inputs: kernel_argument_token.
host_kernel_arguments_delete_token() {
	local kernel_argument_token="$1"
	if [[ "${bootloader_backend_name}" == "${bootloader_backend_rpm_ostree_name}" ]]; then
		"${rpm_ostree_executable_name}" kargs \
			--delete-if-present="${kernel_argument_token}"
		return 0  # rpm-ostree delete finished
	else
		"${grubby_executable_name}" \
			--update-kernel="${grubby_update_kernel_selector}" \
			--remove-args="${kernel_argument_token}"
		return 0  # grubby delete finished
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
		log_error "${grubby_executable_name} --info=DEFAULT failed."
		exit 1
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

# Load staged (next-boot) kernel arguments into
# staged_kernel_arguments_text from rpm-ostree or grubby.
host_read_staged_kernel_arguments() {
	if [[ "${bootloader_backend_name}" == "${bootloader_backend_rpm_ostree_name}" ]]; then
		staged_kernel_arguments_text="$("${rpm_ostree_executable_name}" kargs)"
		return 0  # rpm-ostree kargs listed
	else
		host_read_grubby_default_arguments
		return 0  # grubby DEFAULT parsed
	fi
}

# Tell the user to reboot when live cmdline still has DC disabled.
host_report_reboot_if_live_still_has_disable() {
	if karg_text_contains_token \
		"${live_kernel_arguments_text}" \
		"${display_cstate_disable_kernel_argument}"; then
		log_info "Reboot required before ${display_cstate_disable_kernel_argument} leaves the live kernel."
		return 0  # live still has the karg
	else
		log_info "Live kernel arguments already omit ${display_cstate_disable_kernel_argument}."
		return 0  # live already clean
	fi
}

# =============================================================================
# PATH HELPERS
# =============================================================================

# When started inside distrobox/podman, re-exec on the Fedora host.
# Inputs: original command-line arguments forwarded to the host run.
path_reexec_on_host_if_container() {
	if [[ -f /run/.containerenv || -f /.dockerenv ]]; then
		if command -v distrobox-host-exec >/dev/null 2>&1; then
			local script_absolute_path
			script_absolute_path="$(readlink -f "${BASH_SOURCE[0]}")"
			log_info "Re-running on the host via distrobox-host-exec"
			exec distrobox-host-exec sudo bash "${script_absolute_path}" "$@"
		else
			log_error "Run this uninstaller on the host, not inside a container."
			exit 1
		fi
	else
		return 0  # already on the host
	fi
}

# Exit unless the effective user is root.
path_require_root() {
	if [[ "$(id -u)" -eq 0 ]]; then
		return 0  # running as root
	else
		log_error "Run as root: sudo ${BASH_SOURCE[0]}"
		exit 1
	fi
}

main "$@"
