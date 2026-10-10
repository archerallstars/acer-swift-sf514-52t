#!/usr/bin/env bash
# Install the Acer Swift SF514-52T AVS audio overlay on Fedora Atomic.
#
# Copies this repo's UCM tree into an overlayfs upper dir under /var,
# installs the headset-mic pin reconfig unit, and points PipeWire /
# WirePlumber at the merged UCM tree via ALSA_CONFIG_UCM2. /usr is
# never modified. Must run as root on the host (re-execs via
# distrobox-host-exec when started inside a container).

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Repo layout. Audio scripts live in scripts-audio-fix/. Payload
#     for this fix is still the repo-root ucm2/ and systemd/ trees.
#     Other out-of-tree fixes use their own scripts-<area>-fix/. ---
repository_audio_scripts_directory_name="scripts-audio-fix"

# --- Overlayfs merge of distro ucm2 (lower) plus this machine's files.
#     Merged path is /var/lib/alsa/ucm2/merged so the unit file name
#     var-lib-alsa-ucm2-merged.mount matches systemd-escape. ---
ucm2_lower_directory="/usr/share/alsa/ucm2"
ucm2_overlay_root_directory="/var/lib/alsa/ucm2"
ucm2_upper_directory="/var/lib/alsa/ucm2/upper"
ucm2_work_directory="/var/lib/alsa/ucm2/work"
ucm2_merged_directory="/var/lib/alsa/ucm2/merged"
# Leftovers from the first install that used hyphenated sibling dirs.
legacy_ucm2_upper_directory="/var/lib/alsa/ucm2-upper"
legacy_ucm2_work_directory="/var/lib/alsa/ucm2-work"
legacy_ucm2_merged_directory="/var/lib/alsa/ucm2-merged"

# --- Installed copies of this repo's units and the pin-reconfig script ---
installed_audio_directory="/var/lib/alsa/sf514-audio"
installed_headset_script_path="/var/lib/alsa/sf514-audio/apply-headset-pins.sh"
installed_headset_unit_path="/etc/systemd/system/sf514-alc255-headset.service"
installed_overlay_mount_unit_path="/etc/systemd/system/var-lib-alsa-ucm2-merged.mount"
installed_pipewire_dropin_directory="/etc/systemd/user/pipewire.service.d"
installed_wireplumber_dropin_directory="/etc/systemd/user/wireplumber.service.d"
installed_environment_dropin_directory="/etc/environment.d"
installed_pipewire_dropin_path="/etc/systemd/user/pipewire.service.d/sf514-ucm.conf"
installed_wireplumber_dropin_path="/etc/systemd/user/wireplumber.service.d/sf514-ucm.conf"
installed_environment_dropin_path="/etc/environment.d/50-sf514-alsa-ucm.conf"

# --- systemd unit names (must match the installed file names) ---
overlay_mount_unit_name="var-lib-alsa-ucm2-merged.mount"
headset_unit_name="sf514-alc255-headset.service"

# --- User-session PipeWire stack; sockets are stopped so they cannot
#     immediately restart the services while the codec reconfig runs. ---
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
	echo "sf514-install: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "sf514-install: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Install overlay dirs, UCM files, systemd units, and session drop-ins,
# then reconfig the ALC255 headset pin while the user audio stack is
# stopped. Exits 0 on success, 1 on failure.
main() {
	path_reexec_on_host_if_container "$@"
	path_require_root
	path_require_distro_ucm2
	path_resolve_repository_root
	path_resolve_session_user_name
	host_verify_repository_files
	host_verify_overlay_mount_unit_escape
	directory_create_overlay_paths
	file_io_queue_drain
	directory_reset_known_overlay_files
	file_io_queue_drain
	host_enqueue_install_copies
	file_io_queue_drain
	host_enqueue_selinux_restore
	file_io_queue_drain
	host_reload_systemd_daemon
	host_enable_overlay_mount
	host_enable_headset_unit
	session_stop_user_audio
	if host_restart_headset_unit; then
		:
	else
		session_start_user_audio
		exit 1
	fi
	session_reload_user_systemd
	session_start_user_audio
	log_info "Install complete. Overlay is at ${ucm2_merged_directory}."
	log_info "Run ${repository_audio_scripts_directory_name}/verify.sh as your regular user to check UCM and DMIC."
}

# =============================================================================
# FILE I/O QUEUE
# =============================================================================

# Parallel arrays that hold pending local filesystem jobs. Kinds are
# copy-executable, copy-file, copy-tree, create-directory, remove-path,
# and restore-selinux-context. Copies do not preserve the source
# SELinux type (cp -a from $HOME labels unit files user_home_t).
file_io_job_source_paths=()
file_io_job_destination_paths=()
file_io_job_kinds=()

# Run one queued filesystem job.
# copy-executable and copy-file call install(1) so the destination
# gets the policy default SELinux type rather than user_home_t.
# copy-tree copies directory contents including relative conf.d
# symlinks, without preserving SELinux context.
# create-directory runs mkdir -p.
# remove-path deletes a file or tree.
# restore-selinux-context runs restorecon -FR.
# Inputs: source_path, destination_path, job_kind.
file_io_queue_apply_one_job() {
	local source_path="$1"
	local destination_path="$2"
	local job_kind="$3"
	local restorecon_executable_path
	if [[ "${job_kind}" == "copy-executable" ]]; then
		install -D -m 0755 "${source_path}" "${destination_path}"
	elif [[ "${job_kind}" == "copy-file" ]]; then
		install -D -m 0644 "${source_path}" "${destination_path}"
	elif [[ "${job_kind}" == "copy-tree" ]]; then
		mkdir -p "${destination_path}"
		cp -dR --preserve=timestamps,mode,links "${source_path}/." "${destination_path}/"
	elif [[ "${job_kind}" == "create-directory" ]]; then
		if [[ "${source_path}" == "${destination_path}" ]]; then
			mkdir -p "${destination_path}"
		else
			log_error "create-directory source and destination must be the same path"
			exit 1
		fi
	elif [[ "${job_kind}" == "remove-path" ]]; then
		if [[ "${source_path}" == "${destination_path}" ]]; then
			rm -rf "${destination_path}"
		else
			log_error "remove-path source and destination must be the same path"
			exit 1
		fi
	elif [[ "${job_kind}" == "restore-selinux-context" ]]; then
		if [[ "${source_path}" != "${destination_path}" ]]; then
			log_error "restore-selinux-context source and destination must be the same path"
			exit 1
		else
			if command -v restorecon >/dev/null 2>&1; then
				restorecon_executable_path="$(command -v restorecon)"
			elif [[ -x /usr/sbin/restorecon ]]; then
				restorecon_executable_path="/usr/sbin/restorecon"
			else
				restorecon_executable_path=""
			fi
			if [[ -n "${restorecon_executable_path}" ]]; then
				"${restorecon_executable_path}" -FR "${destination_path}"
			else
				log_info "restorecon not installed; skip SELinux relabel of ${destination_path}"
			fi
		fi
	else
		log_error "Unknown file I/O job kind ${job_kind}"
		exit 1
	fi
}

# Run every queued job in parallel and wait. Exits 1 if any job fails.
# Clears the queue afterwards so a later phase can enqueue new work.
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

# Queue creation of the overlayfs upper, work, and merged directories
# plus the directory that holds the installed pin-reconfig script.
directory_create_overlay_paths() {
	file_io_queue_enqueue \
		"${ucm2_upper_directory}" \
		"${ucm2_upper_directory}" \
		"create-directory"
	file_io_queue_enqueue \
		"${ucm2_work_directory}" \
		"${ucm2_work_directory}" \
		"create-directory"
	file_io_queue_enqueue \
		"${ucm2_merged_directory}" \
		"${ucm2_merged_directory}" \
		"create-directory"
	file_io_queue_enqueue \
		"${installed_audio_directory}" \
		"${installed_audio_directory}" \
		"create-directory"
	file_io_queue_enqueue \
		"${installed_pipewire_dropin_directory}" \
		"${installed_pipewire_dropin_directory}" \
		"create-directory"
	file_io_queue_enqueue \
		"${installed_wireplumber_dropin_directory}" \
		"${installed_wireplumber_dropin_directory}" \
		"create-directory"
	file_io_queue_enqueue \
		"${installed_environment_dropin_directory}" \
		"${installed_environment_dropin_directory}" \
		"create-directory"
	log_info "Queued overlay directories under /var/lib/alsa"
}

# Queue removal of the UCM paths this overlay owns so a reinstall does
# not leave stale files. Drain is done by main before the copy phase.
directory_reset_known_overlay_files() {
	file_io_queue_enqueue \
		"${ucm2_upper_directory}/Intel/avs/avs_hdaudio" \
		"${ucm2_upper_directory}/Intel/avs/avs_hdaudio" \
		"remove-path"
	file_io_queue_enqueue \
		"${ucm2_upper_directory}/Intel/avs/avs_dmic" \
		"${ucm2_upper_directory}/Intel/avs/avs_dmic" \
		"remove-path"
	file_io_queue_enqueue \
		"${ucm2_upper_directory}/conf.d/avs_hdaudio" \
		"${ucm2_upper_directory}/conf.d/avs_hdaudio" \
		"remove-path"
	file_io_queue_enqueue \
		"${ucm2_upper_directory}/conf.d/avs_dmic" \
		"${ucm2_upper_directory}/conf.d/avs_dmic" \
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

# =============================================================================
# HOST SYSTEMD HELPERS
# =============================================================================

# Enable the headset pin unit so it runs on every boot before
# sound.target. Start/restart happens later, after PipeWire is stopped.
host_enable_headset_unit() {
	if systemctl enable "${headset_unit_name}"; then
		log_info "Enabled ${headset_unit_name}"
	else
		log_error "Failed to enable ${headset_unit_name}"
		exit 1
	fi
}

# Enable the overlay mount and start it now so ALSA_CONFIG_UCM2 points
# at a live merge of distro ucm2 plus this machine's files.
host_enable_overlay_mount() {
	if systemctl enable "${overlay_mount_unit_name}"; then
		log_info "Enabled ${overlay_mount_unit_name}"
	else
		log_error "Failed to enable ${overlay_mount_unit_name}"
		systemd-analyze verify "${installed_overlay_mount_unit_path}" || true
		ls -lZ "${installed_overlay_mount_unit_path}" || true
		exit 1
	fi
	if systemctl start "${overlay_mount_unit_name}"; then
		log_info "Started ${overlay_mount_unit_name}"
	else
		log_error "Failed to start ${overlay_mount_unit_name}"
		exit 1
	fi
}

# Queue copies of the UCM tree, pin script, mount unit, headset unit,
# PipeWire/WirePlumber drop-ins, and environment.d file.
host_enqueue_install_copies() {
	file_io_queue_enqueue \
		"${repository_root_directory}/ucm2" \
		"${ucm2_upper_directory}" \
		"copy-tree"
	file_io_queue_enqueue \
		"${repository_root_directory}/${repository_audio_scripts_directory_name}/apply-headset-pins.sh" \
		"${installed_headset_script_path}" \
		"copy-executable"
	file_io_queue_enqueue \
		"${repository_root_directory}/systemd/sf514-alc255-headset.service" \
		"${installed_headset_unit_path}" \
		"copy-file"
	file_io_queue_enqueue \
		"${repository_root_directory}/systemd/var-lib-alsa-ucm2-merged.mount" \
		"${installed_overlay_mount_unit_path}" \
		"copy-file"
	file_io_queue_enqueue \
		"${repository_root_directory}/systemd/sf514-ucm.conf" \
		"${installed_pipewire_dropin_path}" \
		"copy-file"
	file_io_queue_enqueue \
		"${repository_root_directory}/systemd/sf514-ucm.conf" \
		"${installed_wireplumber_dropin_path}" \
		"copy-file"
	file_io_queue_enqueue \
		"${repository_root_directory}/systemd/50-sf514-alsa-ucm.conf" \
		"${installed_environment_dropin_path}" \
		"copy-file"
}

# Relabel installed units and scripts so systemd can read them. Copies
# from the git tree in $HOME otherwise keep user_home_t.
host_enqueue_selinux_restore() {
	file_io_queue_enqueue \
		"${installed_headset_unit_path}" \
		"${installed_headset_unit_path}" \
		"restore-selinux-context"
	file_io_queue_enqueue \
		"${installed_overlay_mount_unit_path}" \
		"${installed_overlay_mount_unit_path}" \
		"restore-selinux-context"
	file_io_queue_enqueue \
		"${installed_pipewire_dropin_directory}" \
		"${installed_pipewire_dropin_directory}" \
		"restore-selinux-context"
	file_io_queue_enqueue \
		"${installed_wireplumber_dropin_directory}" \
		"${installed_wireplumber_dropin_directory}" \
		"restore-selinux-context"
	file_io_queue_enqueue \
		"${installed_environment_dropin_path}" \
		"${installed_environment_dropin_path}" \
		"restore-selinux-context"
	file_io_queue_enqueue \
		"${installed_audio_directory}" \
		"${installed_audio_directory}" \
		"restore-selinux-context"
	file_io_queue_enqueue \
		"${ucm2_overlay_root_directory}" \
		"${ucm2_overlay_root_directory}" \
		"restore-selinux-context"
}

# Reload systemd so newly installed unit files are visible.
host_reload_systemd_daemon() {
	if systemctl daemon-reload; then
		log_info "Reloaded systemd daemon"
	else
		log_error "systemctl daemon-reload failed"
		exit 1
	fi
}

# Restart the headset unit so the pin script runs even on reinstall
# (RemainAfterExit would otherwise make a plain start a no-op). Must
# run while the analog PCM is closed. Returns 1 on failure so main can
# start the user audio stack again before exiting.
host_restart_headset_unit() {
	if systemctl restart "${headset_unit_name}"; then
		log_info "Applied ALC255 headset pin reconfig"
		return 0  # codec reconfig succeeded
	else
		log_error "Headset reconfig failed. Analog PCM was likely still open."
		return 1  # caller restores PipeWire then exits
	fi
}

# Confirm that systemd-escape of the mount unit Where= path matches
# this unit file name. A hyphen in the last path component needs
# \x2d in the unit name, and systemctl enable then reports the unit
# as missing.
host_verify_overlay_mount_unit_escape() {
	local mount_unit_source_path
	local mount_unit_line
	local mount_where_path=""
	local escaped_unit_name
	mount_unit_source_path="${repository_root_directory}/systemd/${overlay_mount_unit_name}"
	if [[ ! -r "${mount_unit_source_path}" ]]; then
		log_error "Cannot read ${mount_unit_source_path}"
		exit 1
	else
		while IFS= read -r mount_unit_line; do
			if [[ "${mount_unit_line}" == Where=* ]]; then
				mount_where_path="${mount_unit_line#Where=}"
			else
				:
			fi
		done < "${mount_unit_source_path}"
		if [[ -z "${mount_where_path}" ]]; then
			log_error "Mount unit ${mount_unit_source_path} has no Where="
			exit 1
		elif command -v systemd-escape >/dev/null 2>&1; then
			escaped_unit_name="$(systemd-escape -p --suffix=mount "${mount_where_path}")"
			if [[ "${escaped_unit_name}" == "${overlay_mount_unit_name}" ]]; then
				log_info "Mount unit name matches systemd-escape of ${mount_where_path}"
				return 0  # unit file name is valid for Where=
			else
				log_error "Mount unit file is ${overlay_mount_unit_name} but Where=${mount_where_path} escapes to ${escaped_unit_name}"
				exit 1
			fi
		else
			log_error "systemd-escape is required to check the mount unit name"
			exit 1
		fi
	fi
}

# Confirm every file the installer copies is present in the repo.
host_verify_repository_files() {
	local required_repository_relative_paths=(
		"ucm2/Intel/avs/avs_hdaudio/AVS HD-Audio.conf"
		"ucm2/Intel/avs/avs_hdaudio/AVS HD-Audio-HiFi.conf"
		"ucm2/Intel/avs/avs_hdaudio/AVS HDMI.conf"
		"ucm2/Intel/avs/avs_hdaudio/AVS HDMI-HiFi.conf"
		"ucm2/Intel/avs/avs_dmic/AVS DMIC.conf"
		"ucm2/Intel/avs/avs_dmic/AVS DMIC-HiFi.conf"
		"ucm2/conf.d/avs_hdaudio/AVS HD-Audio.conf"
		"ucm2/conf.d/avs_hdaudio/AVS HDMI.conf"
		"ucm2/conf.d/avs_dmic/AVS DMIC.conf"
		"${repository_audio_scripts_directory_name}/apply-headset-pins.sh"
		"systemd/sf514-alc255-headset.service"
		"systemd/var-lib-alsa-ucm2-merged.mount"
		"systemd/sf514-ucm.conf"
		"systemd/50-sf514-alsa-ucm.conf"
	)
	local relative_path
	local verification_process_ids=()
	for relative_path in "${required_repository_relative_paths[@]}"; do
		(
			if [[ -e "${repository_root_directory}/${relative_path}" ]]; then
				exit 0
			else
				log_error "Missing ${repository_root_directory}/${relative_path}"
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

# When started inside distrobox/podman, re-exec on the Fedora host so
# units land in the host's /etc and /var rather than the container's.
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

# Exit unless the distro UCM tree (overlay lowerdir) is present.
path_require_distro_ucm2() {
	if [[ -d "${ucm2_lower_directory}" ]]; then
		return 0  # distro ucm2 will be the overlay lowerdir
	else
		log_error "Distro UCM tree missing: ${ucm2_lower_directory}"
		exit 1
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

# Set repository_root_directory to the directory that contains ucm2/.
path_resolve_repository_root() {
	local script_directory
	script_directory="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
	repository_root_directory="$(cd "${script_directory}/.." && pwd)"
	if [[ -d "${repository_root_directory}/ucm2" ]]; then
		return 0  # repo root resolved
	else
		log_error "Cannot find ucm2/ under ${repository_root_directory}"
		exit 1
	fi
}

# Set resolved_session_user_name to the logged-in user whose PipeWire
# stack we must stop around codec reconfig. Prefers SUDO_USER.
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

# Reload the session owner's systemd user daemon so drop-ins apply.
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

# Stop the session owner's PipeWire stack, including sockets, so the
# analog PCM is closed before codec reconfig.
session_stop_user_audio() {
	if [[ -z "${resolved_session_user_name}" ]]; then
		log_info "No session user; stop PipeWire yourself before headset reconfig"
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

# Global filled by path_resolve_repository_root.
repository_root_directory=""
# Global filled by path_resolve_session_user_name.
resolved_session_user_name=""

main "$@"
