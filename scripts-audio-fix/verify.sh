#!/usr/bin/env bash
# Check that AVS audio on the Acer Swift SF514-52T is using this repo's
# UCM overlay. Discovers cards from /proc/asound/cards (does not assume
# card numbers 1/2/3). Does not treat wpctl status as a pass by itself.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Expected ALSA long names after the AVS card rename ---
expected_hd_audio_long_name="AVS HD-Audio"
expected_dmic_long_name="AVS DMIC"
expected_hdmi_long_name="AVS HDMI"
obsolete_card_long_name_fragment="hdaudioB0D2"

# --- Headset mic pin the boot unit must apply ---
required_chip_name="ALC255"
expected_headset_microphone_node="0x19"
expected_headset_microphone_pin_default="0x03a11130"

# --- DMIC capture format that this machine's NHLT actually opens ---
dmic_capture_rate="48000"
dmic_capture_channels="2"
dmic_capture_format="S16_LE"
dmic_capture_duration_seconds="3"
dmic_wav_path="/tmp/sf514-dmic-verify.wav"
dmic_wav_minimum_size_bytes="1000"
dmic_nonzero_sample_scan_bytes="8192"
# Live 'DMIC Volume' boots at 0 (silence). Raw arecord does not go
# through ACP, so verify raises this control before capturing.
dmic_mixer_control_name="DMIC Volume"
dmic_verify_volume_percent="100"

# --- Overlay paths: host first, then distrobox's view of the host ---
ucm2_merged_directory_on_host="/var/lib/alsa/ucm2/merged"
ucm2_merged_directory_from_container="/run/host/var/lib/alsa/ucm2/merged"
overlay_ucm_hd_audio_relative_path="conf.d/avs_hdaudio/AVS HD-Audio.conf"

# --- Kernel / sysfs locations ---
proc_asound_cards_path="/proc/asound/cards"

# =============================================================================
# LOGGER AND CHECK COUNTERS
# =============================================================================

check_pass_count=0
check_fail_count=0
check_skip_count=0

# Print an error line to stderr.
log_error() {
	local log_message="$1"
	echo "sf514-verify: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "sf514-verify: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Run the verification checklist and exit 0 only when every required
# check passed. wpctl status is printed as a note, never as the result.
main() {
	path_resolve_ucm2_merged_directory
	file_read_queue_enqueue "${proc_asound_cards_path}"
	file_read_queue_drain
	cards_parse_proc_asound
	check_overlay_mounted
	check_obsolete_card_names
	check_expected_cards_present
	check_headset_pin
	check_alsaucm_dump
	check_spa_acp_hifi
	check_dmic_capture
	check_wpctl_status_note
	check_kernel_avs_note
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

# Record a skipped check (tool missing or optional hardware absent).
# Inputs: check_name, check_detail.
report_skip() {
	local check_name="$1"
	local check_detail="$2"
	check_skip_count=$((check_skip_count + 1))
	log_info "SKIP  ${check_name}: ${check_detail}"
}

# Print totals and exit 1 when any required check failed.
report_summarize() {
	log_info "Summary: ${check_pass_count} passed, ${check_fail_count} failed, ${check_skip_count} skipped"
	log_info "wpctl status alone is never a pass. HiFi must show in spa-acp-tool."
	if [[ "${check_fail_count}" -ne 0 ]]; then
		exit 1
	else
		exit 0  # every required check passed
	fi
}

# =============================================================================
# FILE READ QUEUE
# =============================================================================

# Paths waiting to be read, and the contents keyed by path after drain.
file_read_job_paths=()
declare -A file_read_queue_contents=()

# Read one file into file_read_queue_contents. Missing files store "".
# Inputs: file_path.
file_read_queue_apply_one_job() {
	local file_path="$1"
	if [[ -r "${file_path}" ]]; then
		file_read_queue_contents["${file_path}"]="$(<"${file_path}")"
	else
		file_read_queue_contents["${file_path}"]=""
	fi
}

# Read every queued path sequentially (bash associative arrays cannot
# be updated from background subshells).
file_read_queue_drain() {
	local file_path
	if [[ "${#file_read_job_paths[@]}" -eq 0 ]]; then
		return 0  # nothing queued
	else
		for file_path in "${file_read_job_paths[@]}"; do
			file_read_queue_apply_one_job "${file_path}"
		done
		file_read_job_paths=()
		return 0  # reads finished
	fi
}

# Append a file path to the read queue. Inputs: file_path.
file_read_queue_enqueue() {
	local file_path="$1"
	file_read_job_paths+=("${file_path}")
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

# Set ucm2_merged_directory to the overlay merge that contains this
# machine's AVS UCM files, or leave it empty when the overlay is absent.
path_resolve_ucm2_merged_directory() {
	if [[ -s "${ucm2_merged_directory_on_host}/${overlay_ucm_hd_audio_relative_path}" ]]; then
		ucm2_merged_directory="${ucm2_merged_directory_on_host}"
	elif [[ -s "${ucm2_merged_directory_from_container}/${overlay_ucm_hd_audio_relative_path}" ]]; then
		ucm2_merged_directory="${ucm2_merged_directory_from_container}"
	else
		ucm2_merged_directory=""
	fi
}

# =============================================================================
# CARD TABLE
# =============================================================================

card_numbers=()
card_ids=()
card_drivers=()
card_long_names=()

# Print the ALSA card id (hw:NAME) for a long name, or return 1.
# Inputs: wanted_long_name.
cards_find_id_by_long_name() {
	local wanted_long_name="$1"
	local card_index
	for card_index in "${!card_long_names[@]}"; do
		if [[ "${card_long_names[card_index]}" == "${wanted_long_name}" ]]; then
			echo "${card_ids[card_index]}"
			return 0  # matching card id
		else
			:
		fi
	done
	return 1  # long name is not in /proc/asound/cards
}

# Print the ALSA card number for a long name, or return 1.
# Inputs: wanted_long_name.
cards_find_number_by_long_name() {
	local wanted_long_name="$1"
	local card_index
	for card_index in "${!card_long_names[@]}"; do
		if [[ "${card_long_names[card_index]}" == "${wanted_long_name}" ]]; then
			echo "${card_numbers[card_index]}"
			return 0  # matching card number
		else
			:
		fi
	done
	return 1  # long name is not in /proc/asound/cards
}

# Fill the card_* arrays from the queued /proc/asound/cards text.
cards_parse_proc_asound() {
	local cards_file_text="${file_read_queue_contents[${proc_asound_cards_path}]:-}"
	local current_line
	local card_id_raw
	local card_long_name_raw
	if [[ -z "${cards_file_text}" ]]; then
		log_error "Cannot read ${proc_asound_cards_path}"
		return 1
	else
		while IFS= read -r current_line; do
			if [[ "${current_line}" =~ ^[[:space:]]*([0-9]+)[[:space:]]+\[([^]]+)\]:[[:space:]]+([^[:space:]]+)[[:space:]]+-[[:space:]]+(.+)$ ]]; then
				card_id_raw="${BASH_REMATCH[2]}"
				card_id_raw="${card_id_raw%"${card_id_raw##*[![:space:]]}"}"
				card_long_name_raw="${BASH_REMATCH[4]}"
				card_long_name_raw="${card_long_name_raw%"${card_long_name_raw##*[![:space:]]}"}"
				card_numbers+=("${BASH_REMATCH[1]}")
				card_ids+=("${card_id_raw}")
				card_drivers+=("${BASH_REMATCH[3]}")
				card_long_names+=("${card_long_name_raw}")
			else
				:
			fi
		done <<< "${cards_file_text}"
		return 0  # card table filled
	fi
}

# =============================================================================
# CHECKS
# =============================================================================

# Run alsaucm dump text for one long name and look for required device
# strings. Empty required strings mean "parse only".
# Inputs: alsaucm_path, wanted_long_name, first_required_string,
# second_required_string.
check_alsaucm_card_dump() {
	local alsaucm_path="$1"
	local wanted_long_name="$2"
	local first_required_string="$3"
	local second_required_string="$4"
	local card_id
	local dump_text
	if card_id="$(cards_find_id_by_long_name "${wanted_long_name}")"; then
		:
	else
		report_fail "alsaucm ${wanted_long_name}" "card not present"
		return 0  # recorded as fail
	fi
	if dump_text="$(
		ALSA_CONFIG_UCM2="${ucm2_merged_directory}" \
			"${alsaucm_path}" -c "hw:${card_id}" dump text 2>&1
	)"; then
		:
	else
		report_fail "alsaucm ${wanted_long_name}" "dump failed: ${dump_text}"
		return 0  # recorded as fail
	fi
	if [[ -n "${first_required_string}" && "${dump_text}" != *"${first_required_string}"* ]]; then
		report_fail "alsaucm ${wanted_long_name}" "dump missing ${first_required_string}"
		return 0  # recorded as fail
	else
		:
	fi
	if [[ -n "${second_required_string}" && "${dump_text}" != *"${second_required_string}"* ]]; then
		report_fail "alsaucm ${wanted_long_name}" "dump missing ${second_required_string}"
		return 0  # recorded as fail
	else
		:
	fi
	report_pass "alsaucm ${wanted_long_name}" "dump parsed for hw:${card_id}"
}

# Dump UCM for HD-Audio, DMIC, and HDMI. Requires alsaucm. HD-Audio
# must mention Speaker and Headphones; DMIC must mention Mic. HDMI
# dump must parse; jack devices need a connected display.
check_alsaucm_dump() {
	local alsaucm_path
	local wanted_long_name
	local first_required_string
	local second_required_string
	if alsaucm_path="$(path_find_executable alsaucm)"; then
		:
	else
		report_skip "alsaucm" "alsaucm not installed; install alsa-utils on the host, spa-acp-tool still checks HiFi"
		return 0  # optional when spa-acp-tool is used
	fi
	if [[ -z "${ucm2_merged_directory}" ]]; then
		report_fail "alsaucm" "ALSA_CONFIG_UCM2 overlay is missing"
		return 0  # further dumps would fail the same way
	else
		export ALSA_CONFIG_UCM2="${ucm2_merged_directory}"
		wanted_long_name="${expected_hd_audio_long_name}"
		first_required_string="Speaker"
		second_required_string="Headphones"
		check_alsaucm_card_dump \
			"${alsaucm_path}" \
			"${wanted_long_name}" \
			"${first_required_string}" \
			"${second_required_string}"
		wanted_long_name="${expected_dmic_long_name}"
		first_required_string="Mic"
		second_required_string=""
		check_alsaucm_card_dump \
			"${alsaucm_path}" \
			"${wanted_long_name}" \
			"${first_required_string}" \
			"${second_required_string}"
		wanted_long_name="${expected_hdmi_long_name}"
		first_required_string=""
		second_required_string=""
		check_alsaucm_card_dump \
			"${alsaucm_path}" \
			"${wanted_long_name}" \
			"${first_required_string}" \
			"${second_required_string}"
		return 0  # per-card results already recorded
	fi
}

# Raise DMIC Volume so a raw arecord is not digital silence.
# Inputs: dmic_card_id — ALSA card id such as DMIC.
check_dmic_apply_volume() {
	local dmic_card_id="$1"
	local amixer_path
	if amixer_path="$(path_find_executable amixer)"; then
		if "${amixer_path}" -c "${dmic_card_id}" cset \
			"name='${dmic_mixer_control_name}'" \
			"${dmic_verify_volume_percent}%"
		then
			log_info "NOTE  Set ${dmic_mixer_control_name} to ${dmic_verify_volume_percent}% on hw:${dmic_card_id}"
			return 0  # mixer is raised for the capture test
		else
			log_info "NOTE  Could not set ${dmic_mixer_control_name}; capture may be silent"
			return 0  # arecord still runs
		fi
	else
		log_info "NOTE  amixer not found; ${dmic_mixer_control_name} may stay at 0%"
		return 0  # arecord still runs
	fi
}

# Record 3 seconds of DMIC audio and require a non-silent WAV.
check_dmic_capture() {
	local arecord_path
	local dmic_card_id
	local wav_file_size_bytes
	local nonzero_sample_line_count
	local arecord_error_text=""
	if arecord_path="$(path_find_executable arecord)"; then
		:
	else
		report_skip "dmic-capture" "arecord not found"
		return 0  # cannot record without arecord
	fi
	if dmic_card_id="$(cards_find_id_by_long_name "${expected_dmic_long_name}")"; then
		:
	else
		report_fail "dmic-capture" "${expected_dmic_long_name} card not present"
		return 0  # recorded as fail
	fi
	check_dmic_apply_volume "${dmic_card_id}"
	if arecord_error_text="$("${arecord_path}" \
		-D "hw:${dmic_card_id},0" \
		-r "${dmic_capture_rate}" \
		-c "${dmic_capture_channels}" \
		-f "${dmic_capture_format}" \
		-d "${dmic_capture_duration_seconds}" \
		"${dmic_wav_path}" \
		2>&1)"
	then
		if [[ -n "${arecord_error_text}" ]]; then
			printf '%s\n' "${arecord_error_text}"
		else
			:
		fi
	else
		if [[ "${arecord_error_text}" == *"Device or resource busy"* ]]; then
			report_skip "dmic-capture" "hw:${dmic_card_id},0 is busy (close GNOME Settings capture meters and re-run)"
			return 0  # PipeWire already holds the PCM
		else
			report_fail "dmic-capture" "arecord failed: ${arecord_error_text}"
			return 0  # recorded as fail
		fi
	fi
	if [[ ! -f "${dmic_wav_path}" ]]; then
		report_fail "dmic-capture" "WAV was not created at ${dmic_wav_path}"
		return 0  # recorded as fail
	else
		wav_file_size_bytes="$(wc -c < "${dmic_wav_path}")"
		if [[ "${wav_file_size_bytes}" -lt "${dmic_wav_minimum_size_bytes}" ]]; then
			report_fail "dmic-capture" "WAV too small (${wav_file_size_bytes} bytes)"
			return 0  # recorded as fail
		else
			nonzero_sample_line_count="$(
				od -An -t u1 -j 44 -N "${dmic_nonzero_sample_scan_bytes}" "${dmic_wav_path}" \
					| tr -s '[:space:]' '\n' \
					| grep -c '[1-9]' \
					|| true
			)"
			if [[ "${nonzero_sample_line_count}" -eq 0 ]]; then
				report_fail "dmic-capture" "first samples are all zeros"
				return 0  # recorded as fail
			else
				report_pass "dmic-capture" "recorded ${wav_file_size_bytes} bytes to ${dmic_wav_path}"
				return 0  # DMIC produced audible-looking samples
			fi
		fi
	fi
}

# Require the three AVS cards this laptop exposes.
check_expected_cards_present() {
	local wanted_long_name
	local card_index
	local card_was_found
	for wanted_long_name in \
		"${expected_hd_audio_long_name}" \
		"${expected_dmic_long_name}" \
		"${expected_hdmi_long_name}"
	do
		card_was_found=0
		for card_index in "${!card_long_names[@]}"; do
			if [[ "${card_long_names[card_index]}" == "${wanted_long_name}" ]]; then
				report_pass "card ${wanted_long_name}" "hw:${card_ids[card_index]} (card ${card_numbers[card_index]}, driver ${card_drivers[card_index]})"
				card_was_found=1
			else
				:
			fi
		done
		if [[ "${card_was_found}" -eq 0 ]]; then
			report_fail "card ${wanted_long_name}" "not in ${proc_asound_cards_path}"
		else
			:
		fi
	done
}

# Require pin 0x19 to be the headset-mic default on the ALC255 codec.
check_headset_pin() {
	local candidate_directory
	local chip_name_value
	local codec_sysfs_directory=""
	local pin_configs_text=""
	shopt -s nullglob
	for candidate_directory in /sys/class/sound/hwC*D0; do
		if [[ -r "${candidate_directory}/chip_name" ]]; then
			chip_name_value="$(<"${candidate_directory}/chip_name")"
			if [[ "${chip_name_value}" == "${required_chip_name}" ]]; then
				codec_sysfs_directory="${candidate_directory}"
			else
				:
			fi
		else
			:
		fi
	done
	if [[ -z "${codec_sysfs_directory}" ]]; then
		report_fail "headset-pin" "${required_chip_name} codec sysfs not found"
		return 0  # recorded as fail
	else
		file_read_queue_enqueue "${codec_sysfs_directory}/init_pin_configs"
		file_read_queue_enqueue "${codec_sysfs_directory}/user_pin_configs"
		file_read_queue_drain
		pin_configs_text="${file_read_queue_contents[${codec_sysfs_directory}/init_pin_configs]}"
		pin_configs_text+=$'\n'
		pin_configs_text+="${file_read_queue_contents[${codec_sysfs_directory}/user_pin_configs]}"
		if [[ "${pin_configs_text}" == *"${expected_headset_microphone_node} ${expected_headset_microphone_pin_default}"* ]]; then
			report_pass "headset-pin" "${expected_headset_microphone_node} is ${expected_headset_microphone_pin_default} on ${codec_sysfs_directory}"
			return 0  # pin fix is in place
		else
			report_fail "headset-pin" "${expected_headset_microphone_node} is not ${expected_headset_microphone_pin_default} (install the overlay, or analog PCM was open during reconfig)"
			return 0  # recorded as fail
		fi
	fi
}

# Note that ACP probe errors in the kernel log are expected.
check_kernel_avs_note() {
	local journalctl_path
	if journalctl_path="$(path_find_executable journalctl)"; then
		if "${journalctl_path}" -k -b 2>/dev/null | grep -q 'Endpoint format configuration not found'; then
			log_info "NOTE  Kernel 'Endpoint format configuration not found' lines during ACP probe are expected."
		else
			log_info "NOTE  No 'Endpoint format configuration not found' lines in this boot's kernel log."
		fi
	else
		:
	fi
}

# Fail if the old SST/AVS long name is still in use (obsolete_card_names).
check_obsolete_card_names() {
	local card_index
	if [[ "${#card_long_names[@]}" -eq 0 ]]; then
		report_fail "card-names" "no cards parsed from ${proc_asound_cards_path}"
		return 0  # recorded as fail
	else
		for card_index in "${!card_long_names[@]}"; do
			if [[ "${card_long_names[card_index]}" == *"${obsolete_card_long_name_fragment}"* ]]; then
				report_fail "card-names" "saw ${card_long_names[card_index]}; unset obsolete_card_names"
				return 0  # recorded as fail
			else
				:
			fi
		done
		report_pass "card-names" "using renamed AVS long names"
		return 0  # names match this overlay
	fi
}

# Require the overlay merge to be visible and export ALSA_CONFIG_UCM2.
check_overlay_mounted() {
	if [[ -z "${ucm2_merged_directory}" ]]; then
		report_fail "overlay" "UCM overlay not found under ${ucm2_merged_directory_on_host} or ${ucm2_merged_directory_from_container}"
		return 0  # recorded as fail
	else
		export ALSA_CONFIG_UCM2="${ucm2_merged_directory}"
		report_pass "overlay" "ALSA_CONFIG_UCM2=${ucm2_merged_directory}"
		return 0  # overlay files are readable
	fi
}

# Probe one card with spa-acp-tool list-profiles and look for HiFi.
# Inputs: spa_acp_tool_path, wanted_long_name, requirement ("required"
# or "optional").
check_spa_acp_card_hifi() {
	local spa_acp_tool_path="$1"
	local wanted_long_name="$2"
	local requirement="$3"
	local card_number
	local profiles_text
	if card_number="$(cards_find_number_by_long_name "${wanted_long_name}")"; then
		:
	else
		report_fail "spa-acp-tool ${wanted_long_name}" "card not present"
		return 0  # recorded as fail
	fi
	if profiles_text="$(
		ALSA_CONFIG_UCM2="${ucm2_merged_directory}" \
			"${spa_acp_tool_path}" -c "${card_number}" list-profiles 2>&1
	)"; then
		:
	else
		profiles_text="spa-acp-tool exited non-zero: ${profiles_text}"
	fi
	if [[ "${profiles_text}" == *"HiFi"* ]]; then
		report_pass "spa-acp-tool ${wanted_long_name}" "HiFi profile present on card ${card_number}"
		return 0  # UCM is being picked up
	else
		if [[ "${requirement}" == "optional" ]]; then
			report_skip "spa-acp-tool ${wanted_long_name}" "no HiFi yet (connect HDMI/DP and re-run); profiles: ${profiles_text}"
			return 0  # HDMI jack may be absent
		else
			report_fail "spa-acp-tool ${wanted_long_name}" "no HiFi profile (still stereo-fallback?). ${profiles_text}"
			return 0  # recorded as fail
		fi
	fi
}

# Require spa-acp-tool to advertise a HiFi profile on HD-Audio and DMIC.
# HDMI HiFi is skipped when no display is connected.
check_spa_acp_hifi() {
	local spa_acp_tool_path
	local wanted_long_name
	local requirement
	if spa_acp_tool_path="$(path_find_executable spa-acp-tool)"; then
		:
	else
		report_fail "spa-acp-tool" "spa-acp-tool not found"
		return 0  # recorded as fail
	fi
	if [[ -z "${ucm2_merged_directory}" ]]; then
		report_fail "spa-acp-tool" "ALSA_CONFIG_UCM2 overlay is missing"
		return 0  # recorded as fail
	else
		export ALSA_CONFIG_UCM2="${ucm2_merged_directory}"
		wanted_long_name="${expected_hd_audio_long_name}"
		requirement="required"
		check_spa_acp_card_hifi \
			"${spa_acp_tool_path}" \
			"${wanted_long_name}" \
			"${requirement}"
		wanted_long_name="${expected_dmic_long_name}"
		requirement="required"
		check_spa_acp_card_hifi \
			"${spa_acp_tool_path}" \
			"${wanted_long_name}" \
			"${requirement}"
		wanted_long_name="${expected_hdmi_long_name}"
		requirement="optional"
		check_spa_acp_card_hifi \
			"${spa_acp_tool_path}" \
			"${wanted_long_name}" \
			"${requirement}"
		return 0  # per-card results already recorded
	fi
}

# Print wpctl status as a note. Never records a pass from this output.
check_wpctl_status_note() {
	local wpctl_path
	local wpctl_status_text
	if wpctl_path="$(path_find_executable wpctl)"; then
		if wpctl_status_text="$("${wpctl_path}" status 2>&1)"; then
			log_info "NOTE  wpctl status (informational, not a pass/fail):"
			printf '%s\n' "${wpctl_status_text}"
		else
			log_info "NOTE  wpctl status failed: ${wpctl_status_text}"
		fi
	else
		log_info "NOTE  wpctl not found; skip session graph dump"
	fi
}

# Runtime path of the merged UCM tree, or empty when the overlay is absent.
ucm2_merged_directory=""

main "$@"
