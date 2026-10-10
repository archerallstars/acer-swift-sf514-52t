#!/usr/bin/env bash
# Apply the Acer Swift SF514-52T headset-mic pin fix to the ALC255 codec.
#
# The Realtek quirk ALC255_FIXUP_ACER_HEADSET_DMIC (PCI SSID 1025:1225)
# does not fire under snd_soc_avs (boot log: PCI SSID 1025:0000). This
# script writes the same pin default the quirk would have set, then
# asks the codec to reparse via sysfs reconfig. It must run before
# PipeWire / WirePlumber open the analog PCM.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Codec identity ---
# chip_name sysfs value on this machine is "ALC255".
required_chip_name="ALC255"

# Pin 0x19 is the 3.5 mm headset mic. BIOS leaves it as 0x411111f0 (N/A).
# Takashi Iwai's SF514-52 quirk sets 0x03a11130.
headset_microphone_node="0x19"
headset_microphone_pin_default="0x03a11130"

# Model string from alc269_fixup_models. Chains headset jack mode without
# treating the headphone as a mic. If this write is rejected, the pin
# default alone is still applied.
headset_model_name="headset-mode-no-hp-mic"

# --- Timing ---
# How long to wait for hwC*D0 to appear after boot.
codec_wait_timeout_seconds=30
codec_wait_interval_seconds=1

# =============================================================================
# LOGGER
# =============================================================================

# Print an informational line to stdout and the system journal when available.
log_info() {
	local message="$1"
	echo "sf514-alc255-headset: ${message}"
	if command -v systemd-cat >/dev/null 2>&1; then
		printf '%s\n' "${message}" | systemd-cat -t sf514-alc255-headset -p info
	else
		:
	fi
}

# Print an error line to stderr and the system journal when available.
log_error() {
	local message="$1"
	echo "sf514-alc255-headset: ${message}" >&2
	if command -v systemd-cat >/dev/null 2>&1; then
		printf '%s\n' "${message}" | systemd-cat -t sf514-alc255-headset -p err
	else
		:
	fi
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Find the ALC255 codec sysfs directory, write the headset pin and model,
# then trigger reconfig. Exits 0 on success, 1 on failure.
main() {
	local codec_sysfs_directory
	codec_sysfs_directory="$(codec_wait_for_alc255)"
	codec_apply_headset_pin "${codec_sysfs_directory}"
	codec_apply_headset_model "${codec_sysfs_directory}"
	codec_trigger_reconfig "${codec_sysfs_directory}"
	log_info "Headset mic pin ${headset_microphone_node} applied on ${codec_sysfs_directory}"
}

# =============================================================================
# CODEC HELPERS
# =============================================================================

# Write the headset-mic pin default into user_pin_configs.
# Inputs: codec_sysfs_directory — path such as /sys/class/sound/hwC1D0.
codec_apply_headset_pin() {
	local codec_sysfs_directory="$1"
	local user_pin_configs_path="${codec_sysfs_directory}/user_pin_configs"
	if [[ ! -w "${user_pin_configs_path}" ]]; then
		log_error "Cannot write ${user_pin_configs_path}"
		exit 1
	else
		printf '%s %s\n' \
			"${headset_microphone_node}" \
			"${headset_microphone_pin_default}" \
			> "${user_pin_configs_path}"
	fi
}

# Write the headset model name. A failure here is non-fatal: the pin
# default is the required part of Takashi's quirk.
# Inputs: codec_sysfs_directory — path such as /sys/class/sound/hwC1D0.
codec_apply_headset_model() {
	local codec_sysfs_directory="$1"
	local modelname_path="${codec_sysfs_directory}/modelname"
	if [[ ! -w "${modelname_path}" ]]; then
		log_info "Skipping modelname; ${modelname_path} is not writable"
	else
		if printf '%s\n' "${headset_model_name}" > "${modelname_path}"; then
			log_info "Set modelname to ${headset_model_name}"
		else
			log_info "modelname write rejected; continuing with pin default only"
		fi
	fi
}

# Locate the sysfs directory whose chip_name is ALC255.
# Returns the directory path on stdout, or exits 1 if none exists yet.
codec_find_alc255_sysfs_directory() {
	local candidate_directory
	local chip_name_value
	shopt -s nullglob
	for candidate_directory in /sys/class/sound/hwC*D0; do
		if [[ -r "${candidate_directory}/chip_name" ]]; then
			chip_name_value="$(<"${candidate_directory}/chip_name")"
			if [[ "${chip_name_value}" == "${required_chip_name}" ]]; then
				echo "${candidate_directory}"
				return 0  # path of the ALC255 codec sysfs directory
			else
				:
			fi
		else
			:
		fi
	done
	return 1  # ALC255 codec sysfs directory not present yet
}

# Trigger codec reparse. Must happen while the analog PCM is closed.
# Writing reconfig tears down the codec sysfs node; the process that
# has the file open is often killed with SIGKILL (exit 137). The write
# runs in a subshell so this script can still exit 0 after storing
# the pin.
# Inputs: codec_sysfs_directory — path such as /sys/class/sound/hwC1D0.
codec_trigger_reconfig() {
	local codec_sysfs_directory="$1"
	local reconfig_path="${codec_sysfs_directory}/reconfig"
	local reconfig_exit_status
	if [[ ! -w "${reconfig_path}" ]]; then
		log_error "Cannot write ${reconfig_path}"
		exit 1
	else
		if ( printf '1\n' > "${reconfig_path}" ); then
			log_info "Codec reconfig wrote on ${reconfig_path}"
			return 0  # reconfig syscall returned
		else
			reconfig_exit_status=$?
			if [[ "${reconfig_exit_status}" -eq 137 ]]; then
				log_info "Codec reconfig child was killed (expected when the codec node is rebuilt)"
				return 0  # pin is already stored; kernel still reparses
			else
				log_error "reconfig failed on ${reconfig_path} (exit ${reconfig_exit_status}; PCM likely already open)"
				exit 1
			fi
		fi
	fi
}

# Poll until the ALC255 codec appears or the timeout expires.
# Returns the sysfs directory path on stdout.
codec_wait_for_alc255() {
	local elapsed_seconds=0
	local codec_sysfs_directory
	while (( elapsed_seconds < codec_wait_timeout_seconds )); do
		if codec_sysfs_directory="$(codec_find_alc255_sysfs_directory)"; then
			echo "${codec_sysfs_directory}"
			return 0  # ALC255 sysfs directory is ready
		else
			sleep "${codec_wait_interval_seconds}"
			elapsed_seconds=$((elapsed_seconds + codec_wait_interval_seconds))
		fi
	done
	log_error "Timed out waiting for ${required_chip_name} codec sysfs"
	exit 1
}

main "$@"
