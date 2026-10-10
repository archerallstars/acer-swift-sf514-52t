#!/usr/bin/env bash
# Remove the Acer Swift SF514-52T AVS audio overlay from Fedora Atomic.
#
# Stops the headset-mic verb unit and the UCM overlay mount, deletes
# the files this repo installed under /etc and /var (including the
# WirePlumber DMIC 51/52 and analog Headset 53/54 gain fragments
# and the combo-jack udev rule), deletes matching home copies of
# those 51-54 filenames, and
# restarts the session PipeWire stack. Idempotent: a second run is a
# successful no-op aside from the session audio restart. Must run as
# root on the host.

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
installed_headset_udev_rule_path="/etc/udev/rules.d/70-sf514-alc255-headset.rules"

# --- WirePlumber system conf.d fragments installed for AVS DMIC
#     (51/52) and analog Headset (53/54) gain. Home copies of the
#     same filenames must be deleted too, or uninstall would leave
#     the DMIC 8x and Headset 4x capture filters in place. ---
wireplumber_dmic_soft_mixer_file_name="51-sf514-dmic-soft-mixer.conf"
wireplumber_dmic_gain_file_name="52-sf514-dmic-gain.conf"
wireplumber_headset_soft_mixer_file_name="53-sf514-headset-soft-mixer.conf"
wireplumber_headset_gain_file_name="54-sf514-headset-gain.conf"
installed_wireplumber_conf_directory="/etc/wireplumber/wireplumber.conf.d"
installed_wireplumber_dmic_soft_mixer_path="${installed_wireplumber_conf_directory}/${wireplumber_dmic_soft_mixer_file_name}"
installed_wireplumber_dmic_gain_path="${installed_wireplumber_conf_directory}/${wireplumber_dmic_gain_file_name}"
installed_wireplumber_headset_soft_mixer_path="${installed_wireplumber_conf_directory}/${wireplumber_headset_soft_mixer_file_name}"
installed_wireplumber_headset_gain_path="${installed_wireplumber_conf_directory}/${wireplumber_headset_gain_file_name}"
session_wireplumber_conf_relative_directory=".config/wireplumber/wireplumber.conf.d"

# --- systemd unit names ---
overlay_mount_unit_name="var-lib-alsa-ucm2-merged.mount"
headset_unit_name="sf514-alc255-headset.service"

# --- User-session PipeWire stack. Do not stop pipewire.socket in the
#     same transaction as pipewire.service: gnome-shell reconnect
#     cancels that socket job. Stop services only; --no-warn hides
#     the triggering-socket line. Restart them after start so
#     drop-in removal takes effect. ---
systemctl_job_mode_replace_irreversibly="--job-mode=replace-irreversibly"
systemctl_no_warn="--no-warn"
user_audio_stop_unit_names=(
	wireplumber.service
	pipewire-pulse.service
	pipewire.service
)
user_audio_restart_unit_names=(
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
# overlay, delete installed files and WirePlumber 51-54 fragments
# (system and session-home copies), reload systemd, start user audio.
# Exits 0 on success, 1 on failure.
main() {
	path_reexec_on_host_if_container "$@"
	path_require_root
	path_resolve_session_user_name
	session_stop_user_audio
	host_disable_headset_unit
	host_disable_overlay_mount
	host_enqueue_uninstall_removes
	session_enqueue_home_dmic_fragment_removes
	file_io_queue_drain
	host_enqueue_empty_directory_cleanup
	file_io_queue_drain
	host_reload_systemd_daemon
	host_reload_udev_rules
	session_reload_user_systemd
	session_start_user_audio
	log_info "Uninstall complete. WirePlumber 51-54 fragments are gone from ${installed_wireplumber_conf_directory} and the session home directory."
	log_info "Log out and back in if CLI tools still export ALSA_CONFIG_UCM2."
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
# /etc/wireplumber/wireplumber.conf.d and the session user's matching
# conf.d directory are removed only when they have no remaining
# fragments from other packages or hand-written confs.
host_enqueue_empty_directory_cleanup() {
	file_io_queue_enqueue \
		"${installed_pipewire_dropin_directory}" \
		"${installed_pipewire_dropin_directory}" \
		"remove-empty-directory"
	file_io_queue_enqueue \
		"${installed_wireplumber_dropin_directory}" \
		"${installed_wireplumber_dropin_directory}" \
		"remove-empty-directory"
	file_io_queue_enqueue \
		"${installed_wireplumber_conf_directory}" \
		"${installed_wireplumber_conf_directory}" \
		"remove-empty-directory"
	if [[ -n "${resolved_session_user_home_directory}" ]]; then
		file_io_queue_enqueue \
			"${resolved_session_user_home_directory}/${session_wireplumber_conf_relative_directory}" \
			"${resolved_session_user_home_directory}/${session_wireplumber_conf_relative_directory}" \
			"remove-empty-directory"
	else
		:
	fi
}

# Queue deletion of every file and directory install.sh created under
# /etc and /var, including the WirePlumber 51-54 gain fragments.
host_enqueue_uninstall_removes() {
	file_io_queue_enqueue \
		"${installed_headset_unit_path}" \
		"${installed_headset_unit_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_headset_udev_rule_path}" \
		"${installed_headset_udev_rule_path}" \
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
		"${installed_wireplumber_dmic_soft_mixer_path}" \
		"${installed_wireplumber_dmic_soft_mixer_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_wireplumber_dmic_gain_path}" \
		"${installed_wireplumber_dmic_gain_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_wireplumber_headset_soft_mixer_path}" \
		"${installed_wireplumber_headset_soft_mixer_path}" \
		"remove-path"
	file_io_queue_enqueue \
		"${installed_wireplumber_headset_gain_path}" \
		"${installed_wireplumber_headset_gain_path}" \
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

# Reload udev so the combo-jack headset-mic rule is dropped.
host_reload_udev_rules() {
	if command -v udevadm >/dev/null 2>&1; then
		if udevadm control --reload-rules; then
			log_info "Reloaded udev rules"
			return 0  # udev no longer references the deleted rule
		else
			log_error "udevadm control --reload-rules failed"
			exit 1
		fi
	else
		log_info "udevadm not installed; skip udev reload"
		return 0  # nothing to reload
	fi
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

# Set resolved_session_user_name and resolved_session_user_home_directory
# for the logged-in user whose PipeWire stack we restart and whose
# home 51/52 WirePlumber copies we delete. Prefers SUDO_USER.
path_resolve_session_user_name() {
	if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
		resolved_session_user_name="${SUDO_USER}"
		log_info "Session user is ${resolved_session_user_name}"
		if command -v getent >/dev/null 2>&1; then
			resolved_session_user_home_directory="$(getent passwd "${resolved_session_user_name}" | cut -d: -f6)"
		else
			resolved_session_user_home_directory="$(awk -F: -v session_user_name="${resolved_session_user_name}" '$1 == session_user_name { print $6; exit }' /etc/passwd)"
		fi
		if [[ -z "${resolved_session_user_home_directory}" ]]; then
			log_info "No home directory for ${resolved_session_user_name}; home WirePlumber fragments will not be removed"
			resolved_session_user_home_directory=""
		else
			log_info "Session home directory is ${resolved_session_user_home_directory}"
		fi
	else
		resolved_session_user_name=""
		resolved_session_user_home_directory=""
		log_info "No SUDO_USER; user PipeWire will not be restarted automatically"
	fi
}

# =============================================================================
# SESSION AUDIO HELPERS
# =============================================================================

# Queue deletion of the session user's home copies of the 51-54
# WirePlumber fragments. Install already removes those copies after
# writing the /etc files. Uninstall still deletes them so a leftover
# experimental copy cannot keep the capture filters after this
# layer is gone.
session_enqueue_home_dmic_fragment_removes() {
	local session_home_dmic_soft_mixer_path
	local session_home_dmic_gain_path
	local session_home_headset_soft_mixer_path
	local session_home_headset_gain_path
	if [[ -z "${resolved_session_user_home_directory}" ]]; then
		log_info "No session home directory; skip removing home WirePlumber fragments"
		return 0  # no home copies to delete
	else
		session_home_dmic_soft_mixer_path="${resolved_session_user_home_directory}/${session_wireplumber_conf_relative_directory}/${wireplumber_dmic_soft_mixer_file_name}"
		session_home_dmic_gain_path="${resolved_session_user_home_directory}/${session_wireplumber_conf_relative_directory}/${wireplumber_dmic_gain_file_name}"
		session_home_headset_soft_mixer_path="${resolved_session_user_home_directory}/${session_wireplumber_conf_relative_directory}/${wireplumber_headset_soft_mixer_file_name}"
		session_home_headset_gain_path="${resolved_session_user_home_directory}/${session_wireplumber_conf_relative_directory}/${wireplumber_headset_gain_file_name}"
		file_io_queue_enqueue \
			"${session_home_dmic_soft_mixer_path}" \
			"${session_home_dmic_soft_mixer_path}" \
			"remove-path"
		file_io_queue_enqueue \
			"${session_home_dmic_gain_path}" \
			"${session_home_dmic_gain_path}" \
			"remove-path"
		file_io_queue_enqueue \
			"${session_home_headset_soft_mixer_path}" \
			"${session_home_headset_soft_mixer_path}" \
			"remove-path"
		file_io_queue_enqueue \
			"${session_home_headset_gain_path}" \
			"${session_home_headset_gain_path}" \
			"remove-path"
		log_info "Queued removal of home copies of ${wireplumber_dmic_soft_mixer_file_name}, ${wireplumber_dmic_gain_file_name}, ${wireplumber_headset_soft_mixer_file_name}, and ${wireplumber_headset_gain_file_name}"
		return 0  # home copies queued for deletion
	fi
}

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

# Start the session owner's PipeWire sockets and WirePlumber, then
# restart the services so removed drop-ins take effect. Inputs: none.
# Exits 0 on success, 1 when start or restart fails.
session_start_user_audio() {
	if [[ -z "${resolved_session_user_name}" ]]; then
		log_info "No session user; start PipeWire from your login session"
		return 0  # nothing to start
	else
		if session_user_systemctl start "${user_audio_start_unit_names[@]}"; then
			if session_user_systemctl \
				"${systemctl_job_mode_replace_irreversibly}" \
				"${systemctl_no_warn}" \
				restart \
				"${user_audio_restart_unit_names[@]}"
			then
				log_info "Started user audio units for ${resolved_session_user_name}"
				return 0  # audio stack started without this overlay's drop-ins
			else
				log_error "Failed to restart user audio services for ${resolved_session_user_name}"
				return 1  # sockets are up but services did not bounce
			fi
		else
			log_error "Failed to start user audio units for ${resolved_session_user_name}"
			return 1  # sockets or WirePlumber did not start
		fi
	fi
}

# Stop the session owner's PipeWire services so analog PCM closes
# before the overlay is unmounted. Does not stop the sockets: a
# gnome-shell reconnect cancels a pipewire.socket stop job. A failed
# stop does not abort uninstall.
session_stop_user_audio() {
	if [[ -z "${resolved_session_user_name}" ]]; then
		log_info "No session user; skip stopping PipeWire"
		return 0  # cannot stop a session we cannot see
	else
		if session_user_systemctl \
			"${systemctl_job_mode_replace_irreversibly}" \
			"${systemctl_no_warn}" \
			stop \
			"${user_audio_stop_unit_names[@]}"
		then
			log_info "Stopped user audio units for ${resolved_session_user_name}"
			return 0  # analog PCM should now be closed
		else
			log_info "Could not stop all user audio services for ${resolved_session_user_name} (a canceled job is common while GNOME holds PipeWire). Continuing uninstall."
			return 0  # overlay files must still be removed
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

# Globals filled by path_resolve_session_user_name.
resolved_session_user_name=""
resolved_session_user_home_directory=""

main "$@"
