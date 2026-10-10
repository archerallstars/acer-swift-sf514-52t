#!/usr/bin/env bash
# Check that AVS audio on the Acer Swift SF514-52T is using this repo's
# UCM overlay, analog headset mic verbs (pin 0x19 IN+VREF_80), the
# Headset UCM device, and the WirePlumber DMIC 51/52 plus analog
# Headset 53/54 gain fragments. Discovers cards from /proc/asound/cards
# (does not assume card numbers 1/2/3). Does not treat wpctl status as
# a pass by itself.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Expected ALSA long names after the AVS card rename ---
expected_hd_audio_long_name="AVS HD-Audio"
expected_dmic_long_name="AVS DMIC"
expected_hdmi_long_name="AVS HDMI"
obsolete_card_long_name_fragment="hdaudioB0D2"

# --- Analog headset mic the boot unit programs with hwdep verbs ---
required_chip_name="ALC255"
expected_headset_microphone_node="0x19"
expected_headset_microphone_pin_ctls_vref80="0x24"
expected_headset_microphone_pin_ctls_vref50="0x22"
required_headset_ucm_device_name="Headset"
overlay_ucm_hd_audio_hifi_relative_path="Intel/avs/avs_hdaudio/AVS HD-Audio-HiFi.conf"

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

# --- WirePlumber system conf.d fragments for AVS DMIC (51/52) and
#     analog Headset (53/54) extra gain. Home copies of the same
#     filenames stack with /etc and apply Mult=4.0 twice. ---
wireplumber_dmic_soft_mixer_file_name="51-sf514-dmic-soft-mixer.conf"
wireplumber_dmic_gain_file_name="52-sf514-dmic-gain.conf"
wireplumber_headset_soft_mixer_file_name="53-sf514-headset-soft-mixer.conf"
wireplumber_headset_gain_file_name="54-sf514-headset-gain.conf"
installed_wireplumber_conf_directory_on_host="/etc/wireplumber/wireplumber.conf.d"
installed_wireplumber_conf_directory_from_container="/run/host/etc/wireplumber/wireplumber.conf.d"
session_wireplumber_conf_relative_directory=".config/wireplumber/wireplumber.conf.d"

# --- Headset verb unit must poll Front Headphone Jack (--watch) ---
headset_unit_file_name="sf514-alc255-headset.service"
installed_headset_unit_on_host="/etc/systemd/system/sf514-alc255-headset.service"
installed_headset_unit_from_container="/run/host/etc/systemd/system/sf514-alc255-headset.service"
required_headset_unit_watch_snippet="--watch"
required_dmic_soft_mixer_snippet="api.alsa.soft-mixer = true"
required_dmic_gain_multiplier_snippet="Mult = 4.0"
# 53 also requires S32LE / 24-bit so GNOME does not open analog capture
# as S16 (that path looks empty on this AVS PCM).
required_headset_audio_format_snippet='audio.format = "S32LE"'
required_headset_resolution_bits_snippet="alsa.resolution_bits = 24"

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
	check_analog_capture_pcm
	check_headset_ucm
	check_headset_unit_watch
	check_alsaucm_dump
	check_spa_acp_hifi
	check_dmic_capture
	check_wireplumber_dmic_fragments
	check_wireplumber_headset_fragments
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

# Print the first readable path among two candidates, or return 1.
# Inputs: first_candidate_path, second_candidate_path.
path_first_readable_file() {
	local first_candidate_path="$1"
	local second_candidate_path="$2"
	if [[ -r "${first_candidate_path}" ]]; then
		echo "${first_candidate_path}"
		return 0  # host path is readable
	elif [[ -r "${second_candidate_path}" ]]; then
		echo "${second_candidate_path}"
		return 0  # container view of the host path is readable
	else
		return 1  # neither path is readable
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

# Require the AVS HD-Audio analog capture PCM (topology pcmC*D0c).
# Capture Switch never appears under snd_soc_avs on this BIOS.
check_analog_capture_pcm() {
	local hd_audio_card_number
	local pcm_capture_info_path
	local pcm_capture_info_text=""
	if hd_audio_card_number="$(cards_find_number_by_long_name "${expected_hd_audio_long_name}")"; then
		:
	else
		report_fail "analog-capture-pcm" "${expected_hd_audio_long_name} card not present"
		return 0  # recorded as fail
	fi
	pcm_capture_info_path="/proc/asound/card${hd_audio_card_number}/pcm0c/info"
	file_read_queue_enqueue "${pcm_capture_info_path}"
	file_read_queue_drain
	pcm_capture_info_text="${file_read_queue_contents[${pcm_capture_info_path}]:-}"
	if [[ "${pcm_capture_info_text}" == *"stream: CAPTURE"* ]]; then
		report_pass "analog-capture-pcm" "AVS topology pcm0c capture exists on card ${hd_audio_card_number} (avs_hdaudio); analog Capture Switch is not required"
		return 0  # AVS analog capture PCM is present
	else
		report_fail "analog-capture-pcm" "${pcm_capture_info_path} has no CAPTURE stream (avs_hdaudio analog PCM)"
		return 0  # recorded as fail
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

# Print one widget block from a codec dump. Bash ${var#*...[Pin]} treats
# [Pin Complex] as a glob class, so callers must not strip with that
# pattern. Inputs: codec_dump_text, widget_node. Output: node block.
codec_extract_node_block() {
	local codec_dump_text="$1"
	local widget_node="$2"
	printf '%s\n' "${codec_dump_text}" | awk -v widget_node="${widget_node}" '
		$1 == "Node" && $2 == widget_node {
			keep = 1
			print
			next
		}
		$1 == "Node" && keep {
			exit
		}
		keep {
			print
		}
	'
	return 0  # awk printed the widget block (empty when the node is missing)
}

# Require live pin 0x19 Pin-ctls IN+VREF_80 (0x24) on the ALC255 codec
# dump. IN+VREF_50 (0x22) still passes as leftover from an older unit;
# the current unit always programs VREF_80. Sysfs user_pin_configs plus
# reconfig cannot retask this ASoC codec.
check_headset_pin() {
	local hd_audio_card_number
	local codec_dump_path
	local codec_dump_text=""
	local headset_microphone_node_block=""
	if hd_audio_card_number="$(cards_find_number_by_long_name "${expected_hd_audio_long_name}")"; then
		:
	else
		report_fail "headset-pin" "${expected_hd_audio_long_name} card not present"
		return 0  # recorded as fail
	fi
	codec_dump_path="/proc/asound/card${hd_audio_card_number}/codec#0"
	file_read_queue_enqueue "${codec_dump_path}"
	file_read_queue_drain
	codec_dump_text="${file_read_queue_contents[${codec_dump_path}]:-}"
	if [[ -z "${codec_dump_text}" ]]; then
		report_fail "headset-pin" "${codec_dump_path} is empty"
		return 0  # recorded as fail
	else
		if [[ "${codec_dump_text}" != *"${required_chip_name}"* ]]; then
			report_fail "headset-pin" "${codec_dump_path} is not ${required_chip_name} (AVS analog card still uses this Realtek codec)"
			return 0  # recorded as fail
		else
			headset_microphone_node_block="$(
				codec_extract_node_block \
					"${codec_dump_text}" \
					"${expected_headset_microphone_node}"
			)"
			if [[ "${headset_microphone_node_block}" == *"Pin-ctls: ${expected_headset_microphone_pin_ctls_vref80}"* ]]; then
				report_pass "headset-pin" "Node ${expected_headset_microphone_node} Pin-ctls ${expected_headset_microphone_pin_ctls_vref80} (IN VREF_80) on ${required_chip_name} ${codec_dump_path}"
				return 0  # analog mic pin is biased for CTIA
			elif [[ "${headset_microphone_node_block}" == *"Pin-ctls: ${expected_headset_microphone_pin_ctls_vref50}"* ]]; then
				report_pass "headset-pin" "Node ${expected_headset_microphone_node} Pin-ctls ${expected_headset_microphone_pin_ctls_vref50} (IN VREF_50 leftover) on ${required_chip_name} ${codec_dump_path}"
				return 0  # leftover bias from an older unit
			else
				report_fail "headset-pin" "Node ${expected_headset_microphone_node} Pin-ctls is not ${expected_headset_microphone_pin_ctls_vref80} or ${expected_headset_microphone_pin_ctls_vref50}; reinstall so the headset unit runs hwdep verbs on avs_hdaudio"
				return 0  # recorded as fail
			fi
		fi
	fi
}

# Require the overlay UCM Headset device, and HiFi capture mapping when
# spa-acp-tool can see the overlay.
check_headset_ucm() {
	local hd_audio_hifi_path=""
	local hd_audio_hifi_text=""
	local spa_acp_tool_path
	local hd_audio_card_number
	local verbose_text=""
	if [[ -z "${ucm2_merged_directory}" ]]; then
		report_fail "headset-ucm" "ALSA_CONFIG_UCM2 overlay is missing"
		return 0  # recorded as fail
	else
		:
	fi
	hd_audio_hifi_path="${ucm2_merged_directory}/${overlay_ucm_hd_audio_hifi_relative_path}"
	file_read_queue_enqueue "${hd_audio_hifi_path}"
	file_read_queue_drain
	hd_audio_hifi_text="${file_read_queue_contents[${hd_audio_hifi_path}]:-}"
	if [[ "${hd_audio_hifi_text}" == *"SectionDevice.\"${required_headset_ucm_device_name}\""* ]]; then
		report_pass "headset-ucm-file" "${hd_audio_hifi_path} defines ${required_headset_ucm_device_name}"
	else
		report_fail "headset-ucm-file" "${hd_audio_hifi_path} is missing SectionDevice.\"${required_headset_ucm_device_name}\""
	fi
	if spa_acp_tool_path="$(path_find_executable spa-acp-tool)"; then
		:
	else
		report_skip "headset-ucm-acp" "spa-acp-tool not found"
		return 0  # overlay file result already recorded
	fi
	if hd_audio_card_number="$(cards_find_number_by_long_name "${expected_hd_audio_long_name}")"; then
		:
	else
		report_fail "headset-ucm-acp" "${expected_hd_audio_long_name} card not present"
		return 0  # recorded as fail
	fi
	if verbose_text="$(
		ALSA_CONFIG_UCM2="${ucm2_merged_directory}" \
			"${spa_acp_tool_path}" -c "${hd_audio_card_number}" list-verbose 2>&1
	)"; then
		:
	else
		verbose_text="spa-acp-tool exited non-zero: ${verbose_text}"
	fi
	if [[ "${verbose_text}" == *"${required_headset_ucm_device_name}"* ]]; then
		report_pass "headset-ucm-acp" "spa-acp-tool lists ${required_headset_ucm_device_name} on card ${hd_audio_card_number}"
		return 0  # UCM Headset reached ACP
	else
		report_fail "headset-ucm-acp" "spa-acp-tool has no ${required_headset_ucm_device_name} on card ${hd_audio_card_number} (restart the session PipeWire stack after install)"
		return 0  # recorded as fail
	fi
}

# Require the headset-mic unit to poll Front Headphone Jack and
# Headphone playback. udev does not emit change events for this ALSA
# input switch, so GET_PIN_SENSE and SYSTEMD_WANTS never re-apply
# UAJ after a plug.
check_headset_unit_watch() {
	local headset_unit_path=""
	local headset_unit_text=""
	if headset_unit_path="$(
		path_first_readable_file \
			"${installed_headset_unit_on_host}" \
			"${installed_headset_unit_from_container}"
	)"; then
		file_read_queue_enqueue "${headset_unit_path}"
		file_read_queue_drain
		headset_unit_text="${file_read_queue_contents[${headset_unit_path}]:-}"
		if [[ "${headset_unit_text}" == *"${required_headset_unit_watch_snippet}"* ]]; then
			report_pass "headset-unit-watch" "${headset_unit_path} runs ${required_headset_unit_watch_snippet} so UAJ re-applies on Front Headphone Jack"
			return 0  # jack-watch verbs are installed
		else
			report_fail "headset-unit-watch" "${headset_unit_path} is missing ${required_headset_unit_watch_snippet}; reinstall so the unit polls the combo jack"
			return 0  # recorded as fail
		fi
	else
		report_fail "headset-unit-watch" "${headset_unit_file_name} missing under /etc/systemd/system"
		return 0  # recorded as fail
	fi
}

# Note that ACP probe errors in the kernel log are expected. Warn if
# this boot still wrote sysfs reconfig (NULL deref on AVS).
check_kernel_avs_note() {
	local journalctl_path
	if journalctl_path="$(path_find_executable journalctl)"; then
		if "${journalctl_path}" -k -b 2>/dev/null | grep -q 'Endpoint format configuration not found'; then
			log_info "NOTE  Kernel 'Endpoint format configuration not found' lines during ACP probe are expected."
		else
			log_info "NOTE  No 'Endpoint format configuration not found' lines in this boot's kernel log."
		fi
		if "${journalctl_path}" -k -b 2>/dev/null | grep -q 'hda-codec: reconfiguring'; then
			log_info "NOTE  This boot wrote sysfs reconfig (oopses on AVS). Reinstall this overlay; the headset unit uses hwdep verbs only."
		else
			:
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

# Require the system WirePlumber 51/52 fragments with the proven DMIC
# soft-mixer and linear Mult=4.0 settings. Home copies of the same
# filenames fail the check because they would stack with /etc.
check_wireplumber_dmic_fragments() {
	local system_soft_mixer_path=""
	local system_gain_path=""
	local session_home_directory="${HOME:-}"
	local home_soft_mixer_path="${session_home_directory}/${session_wireplumber_conf_relative_directory}/${wireplumber_dmic_soft_mixer_file_name}"
	local home_gain_path="${session_home_directory}/${session_wireplumber_conf_relative_directory}/${wireplumber_dmic_gain_file_name}"
	local soft_mixer_text=""
	local gain_text=""
	if system_soft_mixer_path="$(
		path_first_readable_file \
			"${installed_wireplumber_conf_directory_on_host}/${wireplumber_dmic_soft_mixer_file_name}" \
			"${installed_wireplumber_conf_directory_from_container}/${wireplumber_dmic_soft_mixer_file_name}"
	)"; then
		file_read_queue_enqueue "${system_soft_mixer_path}"
	else
		system_soft_mixer_path=""
		report_fail "wireplumber-dmic-soft-mixer" "${wireplumber_dmic_soft_mixer_file_name} missing under ${installed_wireplumber_conf_directory_on_host}"
	fi
	if system_gain_path="$(
		path_first_readable_file \
			"${installed_wireplumber_conf_directory_on_host}/${wireplumber_dmic_gain_file_name}" \
			"${installed_wireplumber_conf_directory_from_container}/${wireplumber_dmic_gain_file_name}"
	)"; then
		file_read_queue_enqueue "${system_gain_path}"
	else
		system_gain_path=""
		report_fail "wireplumber-dmic-gain" "${wireplumber_dmic_gain_file_name} missing under ${installed_wireplumber_conf_directory_on_host}"
	fi
	file_read_queue_drain
	if [[ -n "${system_soft_mixer_path}" ]]; then
		soft_mixer_text="${file_read_queue_contents[${system_soft_mixer_path}]}"
		if [[ "${soft_mixer_text}" == *"${required_dmic_soft_mixer_snippet}"* ]]; then
			report_pass "wireplumber-dmic-soft-mixer" "${system_soft_mixer_path} sets ${required_dmic_soft_mixer_snippet}"
		else
			report_fail "wireplumber-dmic-soft-mixer" "${system_soft_mixer_path} is missing ${required_dmic_soft_mixer_snippet}"
		fi
	else
		:
	fi
	if [[ -n "${system_gain_path}" ]]; then
		gain_text="${file_read_queue_contents[${system_gain_path}]}"
		if [[ "${gain_text}" == *"${required_dmic_gain_multiplier_snippet}"* ]]; then
			report_pass "wireplumber-dmic-gain" "${system_gain_path} sets ${required_dmic_gain_multiplier_snippet}"
		else
			report_fail "wireplumber-dmic-gain" "${system_gain_path} is missing ${required_dmic_gain_multiplier_snippet}"
		fi
	else
		:
	fi
	if [[ -z "${session_home_directory}" ]]; then
		report_skip "wireplumber-dmic-home-copy" "HOME is unset; cannot check for stacked fragments"
		return 0  # system fragment results already recorded
	elif [[ -e "${home_soft_mixer_path}" || -e "${home_gain_path}" ]]; then
		report_fail "wireplumber-dmic-home-copy" "home copies of 51/52 would stack with /etc; delete ${home_soft_mixer_path} and ${home_gain_path}"
		return 0  # recorded as fail
	else
		report_pass "wireplumber-dmic-home-copy" "no home copies of ${wireplumber_dmic_soft_mixer_file_name} or ${wireplumber_dmic_gain_file_name}"
		return 0  # system fragments are the only copies
	fi
}

# Require the system WirePlumber 53/54 fragments with analog Headset
# soft-mixer, S32LE/24-bit, and linear Mult=4.0. Home copies of the
# same filenames fail the check because they would stack with /etc.
check_wireplumber_headset_fragments() {
	local system_soft_mixer_path=""
	local system_gain_path=""
	local session_home_directory="${HOME:-}"
	local home_soft_mixer_path="${session_home_directory}/${session_wireplumber_conf_relative_directory}/${wireplumber_headset_soft_mixer_file_name}"
	local home_gain_path="${session_home_directory}/${session_wireplumber_conf_relative_directory}/${wireplumber_headset_gain_file_name}"
	local soft_mixer_text=""
	local gain_text=""
	if system_soft_mixer_path="$(
		path_first_readable_file \
			"${installed_wireplumber_conf_directory_on_host}/${wireplumber_headset_soft_mixer_file_name}" \
			"${installed_wireplumber_conf_directory_from_container}/${wireplumber_headset_soft_mixer_file_name}"
	)"; then
		file_read_queue_enqueue "${system_soft_mixer_path}"
	else
		system_soft_mixer_path=""
		report_fail "wireplumber-headset-soft-mixer" "${wireplumber_headset_soft_mixer_file_name} missing under ${installed_wireplumber_conf_directory_on_host}"
	fi
	if system_gain_path="$(
		path_first_readable_file \
			"${installed_wireplumber_conf_directory_on_host}/${wireplumber_headset_gain_file_name}" \
			"${installed_wireplumber_conf_directory_from_container}/${wireplumber_headset_gain_file_name}"
	)"; then
		file_read_queue_enqueue "${system_gain_path}"
	else
		system_gain_path=""
		report_fail "wireplumber-headset-gain" "${wireplumber_headset_gain_file_name} missing under ${installed_wireplumber_conf_directory_on_host}"
	fi
	file_read_queue_drain
	if [[ -n "${system_soft_mixer_path}" ]]; then
		soft_mixer_text="${file_read_queue_contents[${system_soft_mixer_path}]}"
		if [[ "${soft_mixer_text}" == *"${required_dmic_soft_mixer_snippet}"* ]]; then
			report_pass "wireplumber-headset-soft-mixer" "${system_soft_mixer_path} sets ${required_dmic_soft_mixer_snippet}"
		else
			report_fail "wireplumber-headset-soft-mixer" "${system_soft_mixer_path} is missing ${required_dmic_soft_mixer_snippet}"
		fi
		if [[ "${soft_mixer_text}" == *"${required_headset_audio_format_snippet}"* ]]; then
			report_pass "wireplumber-headset-format" "${system_soft_mixer_path} sets ${required_headset_audio_format_snippet}"
		else
			report_fail "wireplumber-headset-format" "${system_soft_mixer_path} is missing ${required_headset_audio_format_snippet}"
		fi
		if [[ "${soft_mixer_text}" == *"${required_headset_resolution_bits_snippet}"* ]]; then
			report_pass "wireplumber-headset-resolution" "${system_soft_mixer_path} sets ${required_headset_resolution_bits_snippet}"
		else
			report_fail "wireplumber-headset-resolution" "${system_soft_mixer_path} is missing ${required_headset_resolution_bits_snippet}"
		fi
	else
		:
	fi
	if [[ -n "${system_gain_path}" ]]; then
		gain_text="${file_read_queue_contents[${system_gain_path}]}"
		if [[ "${gain_text}" == *"${required_dmic_gain_multiplier_snippet}"* ]]; then
			report_pass "wireplumber-headset-gain" "${system_gain_path} sets ${required_dmic_gain_multiplier_snippet}"
		else
			report_fail "wireplumber-headset-gain" "${system_gain_path} is missing ${required_dmic_gain_multiplier_snippet}"
		fi
	else
		:
	fi
	if [[ -z "${session_home_directory}" ]]; then
		report_skip "wireplumber-headset-home-copy" "HOME is unset; cannot check for stacked fragments"
		return 0  # system fragment results already recorded
	elif [[ -e "${home_soft_mixer_path}" || -e "${home_gain_path}" ]]; then
		report_fail "wireplumber-headset-home-copy" "home copies of 53/54 would stack with /etc; delete ${home_soft_mixer_path} and ${home_gain_path}"
		return 0  # recorded as fail
	else
		report_pass "wireplumber-headset-home-copy" "no home copies of ${wireplumber_headset_soft_mixer_file_name} or ${wireplumber_headset_gain_file_name}"
		return 0  # system fragments are the only copies
	fi
}

# Print wpctl status as a note. Never records a pass from this output.
# Volume 1.00 on the AVS DMIC is expected; extra gain is the
# WirePlumber linear Mult=4.0 filter inside the capture node.
check_wpctl_status_note() {
	local wpctl_path
	local wpctl_status_text
	log_info "NOTE  wpctl volume 1.00 on the AVS DMIC is expected; extra gain is WirePlumber linear Mult=4.0 inside the node."
	log_info "NOTE  Analog headset capture needs Front Headphone Jack on and Headset Microphone selected. A 3-ring CTIA mic can stay plugged; the watch unit keeps CTIA (0x45=0xd489). Extra analog gain is ADC +12 dB plus WirePlumber Mult=4.0. Raw analog PCM is S32_LE."
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
