#!/usr/bin/env bash
# Install the Acer Swift SF514-52T EgisTec 0570 fingerprint overlay on
# Fedora Atomic. Copies the overlay libfprint into /var/usrlocal, the
# capture tool into /var/usrlocal/bin, and a fprintd drop-in into /etc.
# /usr is never modified. Must run as root on the host.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Repo layout ---
repository_fingerprint_scripts_directory_name="scripts-fingerprint-fix"

# --- Overlay destinations on this Silverblue host ---
installed_library_directory="/var/usrlocal/lib64"
installed_binary_directory="/var/usrlocal/bin"
installed_library_real_path="/var/usrlocal/lib64/libfprint-2.so.2.0.0"
installed_library_soname_path="/var/usrlocal/lib64/libfprint-2.so.2"
installed_library_unversioned_path="/var/usrlocal/lib64/libfprint-2.so"
installed_capture_binary_path="/var/usrlocal/bin/sf514-egis0570-capture"
installed_fprintd_dropin_directory="/etc/systemd/system/fprintd.service.d"
installed_fprintd_dropin_path="/etc/systemd/system/fprintd.service.d/sf514-egis0570.conf"
installed_udev_rules_path="/etc/udev/rules.d/70-sf514-egis0570.rules"

# --- SELinux file context for fprintd_t mmap of the overlay .so ---
selinux_overlay_fcontext_pattern='/var/usrlocal/lib64/libfprint-2\.so(\..*)?'
selinux_overlay_fcontext_type="lib_t"

# --- systemd ---
fprintd_unit_name="fprintd.service"

# =============================================================================
# LOGGER
# =============================================================================

# Print an error line to stderr.
log_error() {
	local log_message="$1"
	echo "sf514-fp-install: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "sf514-fp-install: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Copy overlay files, apply SELinux context, reload systemd, restart
# fprintd. Exits 0 on success, 1 on failure.
main() {
	path_reexec_on_host_if_container "$@"
	path_require_root
	path_resolve_repository_root
	host_verify_repository_files
	directory_create_install_paths
	file_io_queue_drain
	host_enqueue_install_copies
	file_io_queue_drain
	file_io_queue_enqueue \
		"${installed_capture_binary_path}" \
		"${installed_capture_binary_path}" \
		"chmod-executable"
	file_io_queue_drain
	host_apply_selinux_library_context
	host_reload_udev_rules
	host_reload_systemd_daemon
	host_restart_fprintd
	log_info "Install complete. Overlay libfprint is at ${installed_library_soname_path}."
	log_info "Run ${repository_fingerprint_scripts_directory_name}/verify.sh as your regular user."
	log_info "Enrolled prints from the stock swipe driver will not match; enroll again with fprintd-enroll."
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
	if [[ "${job_kind}" == "copy-file" ]]; then
		mkdir -p "$(dirname "${destination_path}")"
		cp -a "${source_path}" "${destination_path}"
	elif [[ "${job_kind}" == "copy-symlink" ]]; then
		mkdir -p "$(dirname "${destination_path}")"
		ln -sfn "${source_path}" "${destination_path}"
	elif [[ "${job_kind}" == "chmod-executable" ]]; then
		if [[ "${source_path}" == "${destination_path}" ]]; then
			chmod 0755 "${destination_path}"
		else
			log_error "chmod-executable source and destination must be the same path"
			exit 1
		fi
	elif [[ "${job_kind}" == "create-directory" ]]; then
		if [[ "${source_path}" == "${destination_path}" ]]; then
			mkdir -p "${destination_path}"
		else
			log_error "create-directory source and destination must be the same path"
			exit 1
		fi
	else
		log_error "Unknown file I/O job kind ${job_kind}"
		exit 1
	fi
}

# Run every queued job in parallel and wait. Exits 1 if any job fails.
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
# DIRECTORY HELPERS
# =============================================================================

# Queue creation of the overlay library, binary, and drop-in directories.
directory_create_install_paths() {
	file_io_queue_enqueue \
		"${installed_library_directory}" \
		"${installed_library_directory}" \
		"create-directory"
	file_io_queue_enqueue \
		"${installed_binary_directory}" \
		"${installed_binary_directory}" \
		"create-directory"
	file_io_queue_enqueue \
		"${installed_fprintd_dropin_directory}" \
		"${installed_fprintd_dropin_directory}" \
		"create-directory"
	log_info "Queued overlay directories under /var/usrlocal and /etc"
}

# =============================================================================
# HOST HELPERS
# =============================================================================

# Persist lib_t on the overlay library so fprintd_t can mmap it.
host_apply_selinux_library_context() {
	if command -v semanage >/dev/null 2>&1; then
		if semanage fcontext -l | grep -F "${selinux_overlay_fcontext_pattern}" >/dev/null 2>&1; then
			log_info "SELinux fcontext for the overlay library already exists"
		else
			if semanage fcontext -a -t "${selinux_overlay_fcontext_type}" \
				"${selinux_overlay_fcontext_pattern}"; then
				log_info "Added SELinux fcontext ${selinux_overlay_fcontext_type} on overlay libfprint"
			else
				log_error "semanage fcontext failed"
				exit 1
			fi
		fi
	else
		log_info "semanage not installed; using chcon (does not survive a full relabel)"
	fi
	if command -v restorecon >/dev/null 2>&1; then
		restorecon -Fv \
			"${installed_library_real_path}" \
			"${installed_library_soname_path}" \
			"${installed_library_unversioned_path}" \
			|| true
	else
		:
	fi
	if command -v chcon >/dev/null 2>&1; then
		chcon -t "${selinux_overlay_fcontext_type}" \
			"${installed_library_real_path}" \
			|| true
	else
		:
	fi
}

# Queue copies of the overlay library, soname links, capture tool, and drop-in.
host_enqueue_install_copies() {
	file_io_queue_enqueue \
		"${repository_root_directory}/fingerprint/dist/lib64/libfprint-2.so.2.0.0" \
		"${installed_library_real_path}" \
		"copy-file"
	file_io_queue_enqueue \
		"libfprint-2.so.2.0.0" \
		"${installed_library_soname_path}" \
		"copy-symlink"
	file_io_queue_enqueue \
		"libfprint-2.so.2" \
		"${installed_library_unversioned_path}" \
		"copy-symlink"
	file_io_queue_enqueue \
		"${repository_root_directory}/fingerprint/dist/bin/sf514-egis0570-capture" \
		"${installed_capture_binary_path}" \
		"copy-file"
	file_io_queue_enqueue \
		"${repository_root_directory}/systemd/sf514-egis0570.conf" \
		"${installed_fprintd_dropin_path}" \
		"copy-file"
	file_io_queue_enqueue \
		"${repository_root_directory}/udev/70-sf514-egis0570.rules" \
		"${installed_udev_rules_path}" \
		"copy-file"
}

# Reload systemd so the fprintd drop-in is visible.
host_reload_systemd_daemon() {
	if systemctl daemon-reload; then
		log_info "Reloaded systemd daemon"
		return 0  # unit list refreshed
	else
		log_error "systemctl daemon-reload failed"
		exit 1
	fi
}

# Reload udev so the seat user can claim the pad for the capture tool.
host_reload_udev_rules() {
	if command -v udevadm >/dev/null 2>&1; then
		udevadm control --reload-rules || true
		udevadm trigger --subsystem-match=usb --action=add || true
		log_info "Reloaded udev rules for 1c7a:0570"
		return 0  # rules reloaded
	else
		log_info "udevadm not found; replug the pad after install for capture-tool access"
		return 0  # capture still works as root
	fi
}

# Restart dbus-activated fprintd so it loads LD_LIBRARY_PATH.
host_restart_fprintd() {
	if systemctl restart "${fprintd_unit_name}"; then
		log_info "Restarted ${fprintd_unit_name}"
		return 0  # fprintd now sees the overlay
	else
		log_info "${fprintd_unit_name} was not running; it will pick up the drop-in on next activation"
		return 0  # dbus activation will start it later
	fi
}

# Confirm every file the installer copies is present in the repo.
host_verify_repository_files() {
	local required_repository_relative_paths=(
		"fingerprint/dist/lib64/libfprint-2.so.2.0.0"
		"fingerprint/dist/bin/sf514-egis0570-capture"
		"systemd/sf514-egis0570.conf"
		"udev/70-sf514-egis0570.rules"
	)
	local relative_path
	local verification_process_ids=()
	for relative_path in "${required_repository_relative_paths[@]}"; do
		(
			if [[ -e "${repository_root_directory}/${relative_path}" ]]; then
				exit 0
			else
				log_error "Missing ${repository_root_directory}/${relative_path}"
				log_error "Build first: fingerprint/capture make, then fingerprint/build-overlay.sh"
				exit 1
			fi
		) &
		verification_process_ids+=("$!")
	done
	local verification_process_id
	local missing_file_count=0
	for verification_process_id in "${verification_process_ids[@]}"; do
		if wait "${verification_process_id}"; then
			:
		else
			missing_file_count=$((missing_file_count + 1))
		fi
	done
	if [[ "${missing_file_count}" -ne 0 ]]; then
		log_error "Repository is incomplete (${missing_file_count} missing paths)"
		exit 1
	else
		return 0  # every required repo path exists
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
			log_error "Run this installer on the Fedora Silverblue host, not inside a container."
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

# Set repository_root_directory to the directory that contains fingerprint/.
path_resolve_repository_root() {
	local script_directory
	script_directory="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
	repository_root_directory="$(cd "${script_directory}/.." && pwd)"
	if [[ -d "${repository_root_directory}/fingerprint" ]]; then
		return 0  # repo root resolved
	else
		log_error "Cannot find fingerprint/ under ${repository_root_directory}"
		exit 1
	fi
}

# Global filled by path_resolve_repository_root.
repository_root_directory=""

main "$@"
