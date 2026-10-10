#!/usr/bin/env bash
# Remove the Acer Swift SF514-52T AVS audio overlay from Fedora Atomic.
#
# Stops the headset reconfig unit and the UCM overlay mount, deletes
# the files this repo installed under /etc and /var, and restarts the
# session PipeWire stack. Idempotent: a second run is a successful no-op
# aside from the session audio restart. Must run as root on the host.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Overlayfs directories created by install.sh ---
ucm2_overlay_root_directory="/var/lib/alsa/ucm2"
installed_audio_directory="/var/lib/alsa/sf514-audio"
# Hyphenated sibling dirs from the first install attempt.
legacy_ucm2_upper_directory="/var/lib/alsa/ucm2-upper"
legacy_ucm2_work_directory="/var/lib/alsa/ucm2-work"
legacy_ucm2_merged_directory="/var/lib/alsa/ucm2-merged"

# --- Installed unit and drop-in paths ---
installed_headset_unit_path="/etc/systemd/system/sf514-alc255-headset.service"
installed_overlay_mount_unit_path="/etc/systemd/system/var-lib-alsa-ucm2-merged.mount"
installed_pipewire_dropin_directory="/etc/systemd/user/pipewire.service.d"
installed_wireplumber_dropin_directory="/etc/systemd/user/wireplumber.service.d"
installed_pipewire_dropin_path="/etc/systemd/user/pipewire.service.d/sf514-ucm.conf"
installed_wireplumber_dropin_path="/etc/systemd/user/wireplumber.service.d/sf514-ucm.conf"
installed_environment_dropin_path="/etc/environment.d/50-sf514-alsa-ucm.conf"

# --- systemd unit names ---
overlay_mount_unit_name="var-lib-alsa-ucm2-merged.mount"
headset_unit_name="sf514-alc255-headset.service"

# --- User-session PipeWire stack ---
user_audio_stop_unit_names=(
	pipewire.socket
	pipewire-pulse.socket
	pipewire.service
	pipewire-pulse.service
	wireplumber.service
)
user_audio_start_unit_names=(
	pipewire.socket
	pipewire-pulse.socket
	wireplumber.service
)

# =============================================================================
# LOGGER
# =============================================================================

# Print an error line to stderr.
log_error() {
	local log_message="$1"
	echo "sf514-uninstall: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "sf514-uninstall: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Reverse install.sh: stop user audio, disable units, unmount the
# overlay, delete installed files, reload systemd, start user audio.
# Exits 0 on success, 1 on failure.
main() {
	path_reexec_on_host_if_container "$@"
	path_require_root
	path_resolve_session_user_name
	session_stop_user_audio
	host_disable_headset_unit
	host_disable_overlay_mount
	host_enqueue_uninstall_removes
	file_io_queue_drain
	host_enqueue_empty_directory_cleanup
	file_io_queue_drain
	host_reload_systemd_daemon
	session_reload_user_systemd
	session_start_user_audio
	log_info "Uninstall complete. Log out and back in if CLI tools still export ALSA_CONFIG_UCM2."
}

# =============================================================================
# FILE I/O QUEUE
# =============================================================================

# Parallel arrays that hold pending local filesystem jobs.
file_io_job_source_paths=()
file_io_job_destination_paths=()
file_io_job_kinds=()

# Run one queued filesystem job. remove-path deletes a file or tree;
# remove-empty-directory removes a directory only when it has no files.
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
# HOST SYSTEMD HELPERS
# =============================================================================

# Stop and disable the headset pin unit. A missing unit is not an error.
host_disable_headset_unit() {
	if systemctl stop "${headset_unit_name}"; then
		log_info "Stopped ${headset_unit_name}"
	else
		log_info "${headset_unit_name} was not running"
	fi
	if systemctl disable "${headset_unit_name}"; then
		log_info "Disabled ${headset_unit_name}"
	else
		log_info "${headset_unit_name} was not enabled"
	fi
}

# Unmount the UCM overlay and disable the mount unit. A missing unit is
# not an error.
host_disable_overlay_mount() {
	if systemctl stop "${overlay_mount_unit_name}"; then
		log_info "Stopped ${overlay_mount_unit_name}"
	else
		log_info "${overlay_mount_unit_name} was not running"
	fi
	if systemctl disable "${overlay_mount_unit_name}"; then
		log_info "Disabled ${overlay_mount_unit_name}"
	else
		log_info "${overlay_mount_unit_name} was not enabled"
	fi
}

# Queue rmdir of drop-in directories after their files are already gone.
host_enqueue_empty_directory_cleanup() {
	file_io_queue_enqueue \
		"${installed_pipewire_dropin_directory}" \
		"${installed_pipewire_dropin_directory}" \
		"remove-empty-directory"
	file_io_queue_enqueue \
		"${installed_wireplumber_dropin_directory}" \
		"${installed_wireplumber_dropin_directory}" \
		"remove-empty-directory"
}

# Queue deletion of every file and directory install.sh created.
host_enqueue_uninstall_removes() {
	file_io_queue_enqueue \
		"${installed_headset_unit_path}" \
		"${installed_headset_unit_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_overlay_mount_unit_path}" \
		"${installed_overlay_mount_unit_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_pipewire_dropin_path}" \
		"${installed_pipewire_dropin_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_wireplumber_dropin_path}" \
		"${installed_wireplumber_dropin_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_environment_dropin_path}" \
		"${installed_environment_dropin_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_audio_directory}" \
		"${installed_audio_directory}" \
		"remove-path"
	file_io_queue_enqueue \
		"${ucm2_overlay_root_directory}" \
		"${ucm2_overlay_root_directory}" \
		"remove-path"
	file_io_queue_enqueue \
		"${legacy_ucm2_upper_directory}" \
		"${legacy_ucm2_upper_directory}" \
		"remove-path"
	file_io_queue_enqueue \
		"${legacy_ucm2_work_directory}" \
		"${legacy_ucm2_work_directory}" \
		"remove-path"
	file_io_queue_enqueue \
		"${legacy_ucm2_merged_directory}" \
		"${legacy_ucm2_merged_directory}" \
		"remove-path"
}

# Reload systemd so removed unit files disappear from the unit list.
host_reload_systemd_daemon() {
	if systemctl daemon-reload; then
		log_info "Reloaded systemd daemon"
		return 0  # unit list refreshed
	else
		log_error "systemctl daemon-reload failed"
		exit 1
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

# Set resolved_session_user_name to the logged-in user whose PipeWire
# stack we restart after removing drop-ins. Prefers SUDO_USER.
path_resolve_session_user_name() {
	if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
		resolved_session_user_name="${SUDO_USER}"
		log_info "Session user is ${resolved_session_user_name}"
	else
		resolved_session_user_name=""
		log_info "No SUDO_USER; user PipeWire will not be restarted automatically"
	fi
}

# =============================================================================
# SESSION AUDIO HELPERS
# =============================================================================

# Reload the session owner's systemd user daemon so dropped drop-ins
# disappear.
session_reload_user_systemd() {
	if [[ -z "${resolved_session_user_name}" ]]; then
		log_info "No session user; skip user daemon-reload"
		return 0  # nothing to reload
	else
		if session_user_systemctl daemon-reload; then
			log_info "Reloaded user systemd for ${resolved_session_user_name}"
			return 0  # user daemon reloaded
		else
			log_error "User daemon-reload failed for ${resolved_session_user_name}"
			return 1
		fi
	fi
}

# Start the session owner's PipeWire sockets and WirePlumber.
session_start_user_audio() {
	if [[ -z "${resolved_session_user_name}" ]]; then
		log_info "No session user; start PipeWire from your login session"
		return 0  # nothing to start
	else
		if session_user_systemctl start "${user_audio_start_unit_names[@]}"; then
			log_info "Started user audio units for ${resolved_session_user_name}"
			return 0  # audio stack started
		else
			log_error "Failed to start user audio units for ${resolved_session_user_name}"
			return 1
		fi
	fi
}

# Stop the session owner's PipeWire stack, including sockets.
session_stop_user_audio() {
	if [[ -z "${resolved_session_user_name}" ]]; then
		log_info "No session user; skip stopping PipeWire"
		return 0  # cannot stop a session we cannot see
	else
		if session_user_systemctl stop "${user_audio_stop_unit_names[@]}"; then
			log_info "Stopped user audio units for ${resolved_session_user_name}"
			return 0  # analog PCM should now be closed
		else
			log_error "Could not stop user audio units for ${resolved_session_user_name}"
			exit 1
		fi
	fi
}

# Run systemctl --user as the resolved session owner from root.
# Inputs: systemctl arguments after --user.
session_user_systemctl() {
	if [[ -z "${resolved_session_user_name}" ]]; then
		log_info "No session user; skip user systemctl: $*"
		return 0  # no user bus to talk to
	else
		systemctl --machine="${resolved_session_user_name}@" --user "$@"
	fi
}

# Global filled by path_resolve_session_user_name.
resolved_session_user_name=""

main "$@"
