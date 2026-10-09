#!/usr/bin/env bash
# Remove the Acer Swift SF514-52T EgisTec 0570 fingerprint overlay.
#
# Restarts fprintd onto the ostree libfprint, deletes the overlay .so,
# capture binary, drop-in, and the SELinux fcontext this repo added.
# Does not delete /var/lib/fprint/ enrolled prints. Idempotent.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

installed_library_real_path="/var/usrlocal/lib64/libfprint-2.so.2.0.0"
installed_library_soname_path="/var/usrlocal/lib64/libfprint-2.so.2"
installed_library_unversioned_path="/var/usrlocal/lib64/libfprint-2.so"
installed_capture_binary_path="/var/usrlocal/bin/sf514-egis0570-capture"
installed_fprintd_dropin_path="/etc/systemd/system/fprintd.service.d/sf514-egis0570.conf"
installed_fprintd_dropin_directory="/etc/systemd/system/fprintd.service.d"
installed_udev_rules_path="/etc/udev/rules.d/70-sf514-egis0570.rules"

selinux_overlay_fcontext_pattern='/var/usrlocal/lib64/libfprint-2\.so(\..*)?'

fprintd_unit_name="fprintd.service"

# =============================================================================
# LOGGER
# =============================================================================

# Print an error line to stderr.
log_error() {
	local log_message="$1"
	echo "sf514-fp-uninstall: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "sf514-fp-uninstall: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Reverse install.sh: restart fprintd onto ostree libfprint after the
# overlay files are gone. Exits 0 on success.
main() {
	path_reexec_on_host_if_container "$@"
	path_require_root
	host_enqueue_uninstall_removes
	file_io_queue_drain
	host_enqueue_empty_directory_cleanup
	file_io_queue_drain
	host_remove_selinux_library_context
	host_reload_udev_rules
	host_reload_systemd_daemon
	host_restart_fprintd
	log_info "Uninstall complete. fprintd will load ostree /usr/lib64/libfprint-2.so.2 again."
	log_info "Enrolled prints in /var/lib/fprint/ were left in place. Use fprintd-delete to remove them."
}

# =============================================================================
# FILE I/O QUEUE
# =============================================================================

file_io_job_source_paths=()
file_io_job_destination_paths=()
file_io_job_kinds=()

# Run one queued filesystem job.
# Inputs: source_path, destination_path, job_kind.
file_io_queue_apply_one_job() {
	local source_path="$1"
	local destination_path="$2"
	local job_kind="$3"
	if [[ "${job_kind}" == "remove-path" ]]; then
		if [[ "${source_path}" == "${destination_path}" ]]; then
			rm -rf "${destination_path}"
		else
			log_error "remove-path source and destination must be the same path"
			exit 1
		fi
	elif [[ "${job_kind}" == "remove-empty-directory" ]]; then
		if [[ "${source_path}" != "${destination_path}" ]]; then
			log_error "remove-empty-directory source and destination must be the same path"
			exit 1
		elif [[ -d "${destination_path}" ]]; then
			rmdir "${destination_path}" 2>/dev/null || true
		else
			:
		fi
	else
		log_error "Unknown file I/O job kind ${job_kind}"
		exit 1
	fi
}

# Run every queued job in parallel and wait.
file_io_queue_drain() {
	local job_index
	local background_process_ids=()
	if [[ "${#file_io_job_kinds[@]}" -eq 0 ]]; then
		return 0  # nothing queued
	else
		for job_index in "${!file_io_job_kinds[@]}"; do
			file_io_queue_apply_one_job \
				"${file_io_job_source_paths[job_index]}" \
				"${file_io_job_destination_paths[job_index]}" \
				"${file_io_job_kinds[job_index]}" &
			background_process_ids+=("$!")
		done
		local background_process_id
		local drain_failed=0
		for background_process_id in "${background_process_ids[@]}"; do
			if wait "${background_process_id}"; then
				:
			else
				drain_failed=1
			fi
		done
		file_io_job_source_paths=()
		file_io_job_destination_paths=()
		file_io_job_kinds=()
		if [[ "${drain_failed}" -ne 0 ]]; then
			log_error "One or more filesystem jobs failed"
			exit 1
		else
			return 0  # every queued job succeeded
		fi
	fi
}

# Append one filesystem job to the queue.
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
# HOST HELPERS
# =============================================================================

# Queue rmdir of the drop-in directory after its file is gone.
host_enqueue_empty_directory_cleanup() {
	file_io_queue_enqueue \
		"${installed_fprintd_dropin_directory}" \
		"${installed_fprintd_dropin_directory}" \
		"remove-empty-directory"
}

# Queue deletion of every file install.sh created.
host_enqueue_uninstall_removes() {
	file_io_queue_enqueue \
		"${installed_library_real_path}" \
		"${installed_library_real_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_library_soname_path}" \
		"${installed_library_soname_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_library_unversioned_path}" \
		"${installed_library_unversioned_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_capture_binary_path}" \
		"${installed_capture_binary_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_fprintd_dropin_path}" \
		"${installed_fprintd_dropin_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_udev_rules_path}" \
		"${installed_udev_rules_path}" \
		"remove-path"
}

# Reload udev after deleting the overlay rule.
host_reload_udev_rules() {
	if command -v udevadm >/dev/null 2>&1; then
		udevadm control --reload-rules || true
		udevadm trigger --subsystem-match=usb --action=add || true
		log_info "Reloaded udev rules"
		return 0  # rules reloaded
	else
		return 0  # nothing to reload
	fi
}

# Reload systemd so the removed drop-in disappears.
host_reload_systemd_daemon() {
	if systemctl daemon-reload; then
		log_info "Reloaded systemd daemon"
		return 0  # unit list refreshed
	else
		log_error "systemctl daemon-reload failed"
		exit 1
	fi
}

# Remove only the SELinux fcontext this overlay added.
host_remove_selinux_library_context() {
	if command -v semanage >/dev/null 2>&1; then
		if semanage fcontext -l | grep -F "${selinux_overlay_fcontext_pattern}" >/dev/null 2>&1; then
			if semanage fcontext -d "${selinux_overlay_fcontext_pattern}"; then
				log_info "Removed SELinux fcontext for the overlay library"
			else
				log_info "Could not delete SELinux fcontext; it may already be gone"
			fi
		else
			log_info "No overlay SELinux fcontext to remove"
		fi
	else
		log_info "semanage not installed; skip fcontext removal"
	fi
}

# Restart fprintd so it loads ostree libfprint again.
host_restart_fprintd() {
	if systemctl restart "${fprintd_unit_name}"; then
		log_info "Restarted ${fprintd_unit_name}"
		return 0  # fprintd now uses ostree libfprint
	else
		log_info "${fprintd_unit_name} was not running"
		return 0  # nothing to restart
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
			log_info "Re-running on the Fedora host via distrobox-host-exec"
			exec distrobox-host-exec sudo bash "${script_absolute_path}" "$@"
		else
			log_error "Run this uninstaller on the Fedora Silverblue host, not inside a container."
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
