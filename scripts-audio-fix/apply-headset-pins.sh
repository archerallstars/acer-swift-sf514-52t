#!/usr/bin/env bash
# Enable the Acer Swift SF514-52T analog headset mic on Intel AVS.
#
# Under snd_soc_avs the ALC255 codec still runs snd_hda_codec_alc269,
# but BIOS leaves analog mic pins N/A, so autoconfig has empty inputs
# and no Capture Switch. AVS topology already exposes analog capture
# as pcmC*D0c (HDAudio Analog). Sysfs reconfig cannot retask the
# parser: writing hwC*D0/reconfig hits a NULL deref in
# snd_hda_codec_reset (ASoC-bound codec, no PCI snd_card lock).
#
# This script never writes reconfig. It programs the live codec through
# the HDA hwdep: D0 on the analog path, pin 0x19 IN+VREF_80 after
# CTIA, unmute the ADC mixers into 0x19, unmute both ADCs, write the
# headset-mic pin default, then Realtek UAJ. Jack presence is the
# ALSA CARD control "Front Headphone Jack" (hwdep GET_PIN_SENSE stays
# 0 on this AVS codec). A present jack always gets CTIA (0x45=0xd489)
# with pin 0x19 IN+VREF_80 (0x24) and pin 0x21 HP Out (0xc0).
# Unplugged UAJ gates MIC2 Vref, so pin 0x19 then reads 0x20
# (IN VREF_HIZ). That is the Acer 1213187 headset-mic mode, and it
# keeps 2-ring headphone playback working. Kernel mic-in
# (0x45=0xc489, HP pin off) is not used: it captured only noise on
# a 2-ring analog mic and silenced 2-ring headphones. Immediate
# CTIA-vs-OMTP probes on this AVS codec return OMTP after a replug
# and kill capture; Headphone playback on/off is ignored so PipeWire
# mixer changes cannot flip UAJ. --watch debounces the jack and
# re-applies CTIA when coef 0x45 drifts, so a 3-ring mic
# left plugged survives reboot and session audio restarts. UCM
# binds analog capture as Headset.
#
# SUSE bug 1213187 (model=1025:1330) applied on snd-hda-intel. Those
# pin defaults are the hardware map this verb sequence follows.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Codec identity ---
# chip_name sysfs value on this machine is "ALC255".
required_chip_name="ALC255"

# Host python used to issue SNDRV_HDA_IOCTL_VERB_WRITE (CAP_SYS_RAWIO).
python3_executable="/usr/bin/python3"

# --- Headset mic pin and HDA verbs ---
# Pin 0x19 is the combo-jack headset mic. SET_PIN_WIDGET_CONTROL 0x24
# is IN plus VREF_80 (electret bias). GET_PIN_WIDGET_CONTROL reads it
# back.
headset_microphone_node="0x19"
pin_widget_control_set_verb="0x707"
pin_widget_control_get_verb="0xf07"
pin_widget_control_in_vref80="0x24"
# Unplugged UAJ writes MIC2 Vref gated (0x06=0x6104). The codec then
# reports pin 0x19 as IN plus VREF_HIZ even after SET 0x24.
pin_widget_control_in_vref_hiz="0x20"

# Iwai's ALC255_FIXUP_ACER_HEADSET_DMIC pin default for SSID 1025:1225
# (headset mic, no presence). SET_CONFIG_DEFAULT_BYTES_0..3.
headset_microphone_pin_default="0x03a11130"
pin_config_default_bytes0_set_verb="0x71c"
pin_config_default_bytes1_set_verb="0x71d"
pin_config_default_bytes2_set_verb="0x71e"
pin_config_default_bytes3_set_verb="0x71f"
pin_config_default_get_verb="0xf1c"

# Combo-jack headphone pin. hwdep GET_PIN_SENSE stays 0 on this AVS
# codec even when the jack is plugged; the live kcontrol is
# iface=CARD,name='Front Headphone Jack'. Pin 0x21 is OUT-only.
# Kernel mic-in wrote this pin to 0 and silenced 2-ring headphones.
headphone_node="0x21"
headphone_pin_control_hp_out="0xc0"
# Pin-ctls 0x00 turns a pin off (no IN/OUT, VREF_HIZ).
pin_widget_control_off="0x00"
# Pin 0x1a is unused on this chassis (NO_HP_MIC). Mic-in biased it
# as headphone-mic; CTIA and unplugged keep it off.
headphone_microphone_node="0x1a"
amixer_executable="/usr/bin/amixer"
front_headphone_jack_mixer_name="Front Headphone Jack"
front_headphone_jack_values_on="values=on"
front_headphone_jack_values_off="values=off"

# Pin 0x19 Amp-In: ofs=0, nsteps=3, stepsize ~10 dB, no mute bit.
# SET_AMP_GAIN_MUTE payload 0x7003 is Input+Left+Right+index 0, gain 3.
amp_gain_mute_set_verb="0x300"
headset_microphone_pin_amp_boost_payload="0x7003"

# ADC mux mixers. Connection lists put 0x19 at index 1 and 0x1a at
# index 2 on both. SET_AMP_GAIN_MUTE payload 0x7100 unmutes index 1;
# 0x7280 mutes index 2 so leftover mic-in cannot keep 0x1a in the mix.
adc_mixer_node_primary="0x22"
adc_mixer_node_secondary="0x23"
headset_microphone_mixer_unmute_payload="0x7100"
headphone_microphone_mixer_mute_payload="0x7280"

# Analog ADCs that feed AVS "HDAudio Analog" capture. Amp-In ofs=0x17
# is 0 dB (stepsize 0x02 is 0.75 dB/step). Payload 0x7027 unmutes
# both channels at 0x17+16 steps, about +12 dB, so GNOME's meter
# moves on this quiet CTIA electret.
adc_node_primary="0x08"
adc_node_secondary="0x09"
adc_unmute_payload="0x7027"

# SET_POWER_STATE. Autoconfig with empty inputs may leave analog ADCs
# in D3; the pin and mixers need D0 before IN+VREF and unmute stick.
power_state_set_verb="0x705"
power_state_d0="0x00"

# Vendor node 0x20. SET_COEF_INDEX 0x500, SET_PROC_COEF 0x400,
# GET_PROC_COEF 0xc00. WRITE_COEFEX uses the same verbs on nid 0x57
# (hidden vendor processing node; it is not a widget in the dump).
vendor_coefficient_node="0x20"
coefex_processing_node="0x57"
coef_index_set_verb="0x500"
coef_data_set_verb="0x400"
coef_data_get_verb="0xc00"
alc255_default_jack_coef_index_1b="0x1b"
alc255_default_jack_coef_value_1b_prepare="0x880b"
alc255_default_jack_coef_index_45="0x45"
alc255_default_jack_coef_value_45="0xd089"
alc255_default_jack_coef_value_1b_commit="0x080b"
alc255_default_jack_coef_index_46="0x46"
alc255_default_jack_coef_value_46="0x0004"
alc255_default_jack_coef_value_1b_finish="0x0c0b"
alc255_ctia_headset_mode_coef_index_45="0x45"
alc255_ctia_headset_mode_coef_value_45="0xd489"
alc255_ctia_headset_mode_coef_index_1b="0x1b"
alc255_ctia_headset_mode_coef_value_1b="0x0c2b"
alc255_plugged_coefex_index="0x03"
alc255_plugged_coefex_value="0x8ea6"
alc255_unplugged_coef_index_1b="0x1b"
alc255_unplugged_coef_value_1b="0x0c0b"
alc255_unplugged_coef_index_45="0x45"
alc255_unplugged_coef_value_45="0xd089"
alc255_unplugged_coefex_index="0x03"
alc255_unplugged_coefex_value="0x8aa6"
alc255_mic2_vref_coef_index="0x06"
alc255_mic2_vref_ungated_value="0x6100"
alc255_mic2_vref_gated_value="0x6104"

# --- Timing ---
# How long to wait for hwC*D0 to appear after boot.
codec_wait_timeout_seconds=30
codec_wait_interval_seconds=1
# Kernel alc255_set_default_jack_type sleeps 30 ms before headset mode.
alc255_default_jack_type_settle_seconds="0.03"
# How often --watch re-reads Front Headphone Jack.
watch_jack_poll_seconds="0.5"
# Consecutive matching jack polls before UAJ follows a plug or unplug
# (3 * 0.5 s = 1.5 s). Stops a bounce from applying unplugged UAJ.
watch_jack_stable_polls=3
watch_argument="--watch"

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

# Find the ALC255 codec, open its hwdep, and program the analog headset
# mic path. --watch keeps the process running, debounces the jack, and
# re-applies CTIA when coef 0x45 drifts. Never writes sysfs reconfig.
# Exits 0 on success, 1 on failure.
main() {
	local codec_sysfs_directory
	local hwdep_device_path
	local watch_jack_events=0
	local command_argument
	for command_argument in "$@"; do
		if [[ "${command_argument}" == "${watch_argument}" ]]; then
			watch_jack_events=1
		else
			log_error "Unknown argument ${command_argument} (supported: ${watch_argument})"
			exit 1
		fi
	done
	codec_sysfs_directory="$(codec_wait_for_alc255)"
	hwdep_device_path="$(codec_find_hwdep_path "${codec_sysfs_directory}")"
	codec_program_headset_microphone_path "${hwdep_device_path}"
	if [[ "${watch_jack_events}" -eq 1 ]]; then
		codec_watch_headphone_jack "${hwdep_device_path}"
	else
		:
	fi
}

# =============================================================================
# CODEC I/O
# =============================================================================

# Read one Realtek processing coefficient from node 0x20.
# Inputs: hwdep_device_path, coefficient_index. Output: hex value.
codec_read_realtek_coef() {
	local hwdep_device_path="$1"
	local coefficient_index="$2"
	local coefficient_value
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${vendor_coefficient_node}" \
		"${coef_index_set_verb}" \
		"${coefficient_index}" \
		>/dev/null
	coefficient_value="$(
		codec_write_hda_verb \
			"${hwdep_device_path}" \
			"${vendor_coefficient_node}" \
			"${coef_data_get_verb}" \
			"0x0"
	)"
	echo "${coefficient_value}"
	return 0  # hex coefficient from GET_PROC_COEF
}

# Issue one HDA verb through SNDRV_HDA_IOCTL_VERB_WRITE. Packing matches
# alsa-tools hda-verb: nid<<24 | verb<<8 | param (4/16 and 12/8 overlap
# into a valid bus command). The kernel ioctl keeps only param&0xff, so
# 16-bit payloads (amp, coef) must ride in that overlap. Inputs:
# hwdep_device_path, widget_node, verb_id, verb_parameter. Output:
# response as a hex string on stdout. Do not log on stdout; GET
# callers capture this.
codec_write_hda_verb() {
	local hwdep_device_path="$1"
	local widget_node="$2"
	local verb_id="$3"
	local verb_parameter="$4"
	local verb_result
	if [[ ! -x "${python3_executable}" ]]; then
		log_error "${python3_executable} is missing; cannot talk to ${hwdep_device_path}"
		exit 1
	else
		:
	fi
	if verb_result="$(
		"${python3_executable}" - \
			"${hwdep_device_path}" \
			"${widget_node}" \
			"${verb_id}" \
			"${verb_parameter}" <<'PY'
import fcntl
import os
import struct
import sys

hwdep_device_path = sys.argv[1]
widget_node = int(sys.argv[2], 0)
verb_id = int(sys.argv[3], 0)
verb_parameter = int(sys.argv[4], 0)
packed_command = (
    ((widget_node & 0xFF) << 24)
    | ((verb_id & 0xFFFF) << 8)
    | (verb_parameter & 0xFFFF)
)
# _IOWR('H', 0x11, 8) on linux x86_64
hda_ioctl_verb_write = 0xC0084811
file_descriptor = os.open(hwdep_device_path, os.O_RDWR)
try:
    ioctl_buffer = bytearray(struct.pack("II", packed_command, 0))
    fcntl.ioctl(file_descriptor, hda_ioctl_verb_write, ioctl_buffer)
    response_value = struct.unpack("II", bytes(ioctl_buffer))[1]
finally:
    os.close(file_descriptor)
print(hex(response_value))
PY
	)"; then
		echo "${verb_result}"
		return 0  # hex response from the codec
	else
		log_error "verb ${widget_node} ${verb_id} ${verb_parameter} failed on ${hwdep_device_path}"
		exit 1
	fi
}

# Write one Realtek processing coefficient through node 0x20.
# Inputs: hwdep_device_path, coefficient_index, coefficient_value.
codec_write_realtek_coef() {
	local hwdep_device_path="$1"
	local coefficient_index="$2"
	local coefficient_value="$3"
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${vendor_coefficient_node}" \
		"${coef_index_set_verb}" \
		"${coefficient_index}" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${vendor_coefficient_node}" \
		"${coef_data_set_verb}" \
		"${coefficient_value}" \
		>/dev/null
}

# Write one processing coefficient on an arbitrary vendor widget
# (node 0x20 WRITE_COEF, or node 0x57 WRITE_COEFEX).
# Inputs: hwdep_device_path, widget_node, coefficient_index,
# coefficient_value.
codec_write_realtek_coef_on_widget() {
	local hwdep_device_path="$1"
	local widget_node="$2"
	local coefficient_index="$3"
	local coefficient_value="$4"
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${widget_node}" \
		"${coef_index_set_verb}" \
		"${coefficient_index}" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${widget_node}" \
		"${coef_data_set_verb}" \
		"${coefficient_value}" \
		>/dev/null
}

# =============================================================================
# CODEC DISCOVERY
# =============================================================================

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

# Map a codec sysfs directory such as /sys/class/sound/hwC2D0 to
# /dev/snd/hwC2D0. Inputs: codec_sysfs_directory. Output: hwdep path.
codec_find_hwdep_path() {
	local codec_sysfs_directory="$1"
	local hwdep_device_path="/dev/snd/$(basename "${codec_sysfs_directory}")"
	if [[ -e "${hwdep_device_path}" ]]; then
		echo "${hwdep_device_path}"
		return 0  # hwdep device path
	else
		log_error "HDA hwdep ${hwdep_device_path} is missing"
		exit 1
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

# =============================================================================
# CODEC PATH PROGRAMMING
# =============================================================================

# Turn headphone pin 0x21 to HP Out and pin 0x1a off. Kernel mic-in
# wrote pin 0x21 to 0, which silenced 2-ring headphones. Inputs:
# hwdep_device_path.
codec_restore_headphone_playback_pins() {
	local hwdep_device_path="$1"
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${headphone_node}" \
		"${pin_widget_control_set_verb}" \
		"${headphone_pin_control_hp_out}" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${headphone_microphone_node}" \
		"${pin_widget_control_set_verb}" \
		"${pin_widget_control_off}" \
		>/dev/null
	log_info "Restored pin ${headphone_node} HP Out ${headphone_pin_control_hp_out} and pin ${headphone_microphone_node} off"
}

# Apply alc_headset_mode_ctia for ALC255 (plugged iPhone-style TRRS).
# 0x45=0xd489 and 0x1b=0x0c2b switch UAJ to headset-mic. 0x06=0x6100
# ungates MIC2 Vref. WRITE_COEFEX 0x57/0x03=0x8ea6 is the kernel CTIA
# direct-drive HP amp value. Also restores pin 0x21 HP Out and
# turns pin 0x1a off so leftover mic-in cannot silence 2-ring
# headphones. Inputs: hwdep_device_path.
codec_apply_alc255_ctia_headset_mode() {
	local hwdep_device_path="$1"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_ctia_headset_mode_coef_index_45}" \
		"${alc255_ctia_headset_mode_coef_value_45}"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_ctia_headset_mode_coef_index_1b}" \
		"${alc255_ctia_headset_mode_coef_value_1b}"
	codec_write_realtek_coef_on_widget \
		"${hwdep_device_path}" \
		"${coefex_processing_node}" \
		"${alc255_plugged_coefex_index}" \
		"${alc255_plugged_coefex_value}"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_mic2_vref_coef_index}" \
		"${alc255_mic2_vref_ungated_value}"
	codec_restore_headphone_playback_pins "${hwdep_device_path}"
	log_info "Set ALC255 CTIA plugged headset mode (0x45=${alc255_ctia_headset_mode_coef_value_45}, pin ${headphone_node}=${headphone_pin_control_hp_out})"
}

# Write the ALC255 alc255_set_default_jack_type sequence (UAJ manual,
# 0x45=0xd089). Call this before codec_apply_headset_jack_mode.
# Inputs: hwdep_device_path.
codec_apply_alc255_default_jack_type() {
	local hwdep_device_path="$1"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_default_jack_coef_index_1b}" \
		"${alc255_default_jack_coef_value_1b_prepare}"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_default_jack_coef_index_45}" \
		"${alc255_default_jack_coef_value_45}"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_default_jack_coef_index_1b}" \
		"${alc255_default_jack_coef_value_1b_commit}"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_default_jack_coef_index_46}" \
		"${alc255_default_jack_coef_value_46}"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_default_jack_coef_index_1b}" \
		"${alc255_default_jack_coef_value_1b_finish}"
	log_info "Set ALC255 default jack-type coefficients"
}

# Apply alc_headset_mode_unplugged for ALC255. 0x45=0xd089, MIC2 Vref
# gated with HP, COEFEX 0x8aa6. Restores pin 0x21 as HP Out and
# turns pin 0x1a off. Inputs: hwdep_device_path.
codec_apply_alc255_unplugged_headset_mode() {
	local hwdep_device_path="$1"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_unplugged_coef_index_1b}" \
		"${alc255_unplugged_coef_value_1b}"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_unplugged_coef_index_45}" \
		"${alc255_unplugged_coef_value_45}"
	codec_write_realtek_coef \
		"${hwdep_device_path}" \
		"${alc255_mic2_vref_coef_index}" \
		"${alc255_mic2_vref_gated_value}"
	codec_write_realtek_coef_on_widget \
		"${hwdep_device_path}" \
		"${coefex_processing_node}" \
		"${alc255_unplugged_coefex_index}" \
		"${alc255_unplugged_coefex_value}"
	codec_restore_headphone_playback_pins "${hwdep_device_path}"
	log_info "Set ALC255 unplugged UAJ mode (0x45=${alc255_unplugged_coef_value_45}); plug a CTIA TRRS headset to enable analog capture"
}

# Map /dev/snd/hwC2D0 to ALSA card number 2.
# Inputs: hwdep_device_path. Output: decimal card number.
codec_alsa_card_number_from_hwdep() {
	local hwdep_device_path="$1"
	local hwdep_basename
	hwdep_basename="$(basename "${hwdep_device_path}")"
	if [[ "${hwdep_basename}" =~ ^hwC([0-9]+)D[0-9]+$ ]]; then
		echo "${BASH_REMATCH[1]}"
		return 0  # ALSA card number
	else
		log_error "Cannot parse ALSA card number from ${hwdep_device_path}"
		exit 1
	fi
}

# Return 0 when iface=CARD,name='Front Headphone Jack' is on.
# hwdep GET_PIN_SENSE is not used: it stays 0 on this AVS codec while
# the kcontrol tracks the real plug. Silent on purpose so --watch can
# poll it. Inputs: hwdep_device_path.
codec_headphone_jack_is_present() {
	local hwdep_device_path="$1"
	local alsa_card_number
	local jack_control_text
	alsa_card_number="$(codec_alsa_card_number_from_hwdep "${hwdep_device_path}")"
	if [[ ! -x "${amixer_executable}" ]]; then
		log_error "${amixer_executable} is missing; cannot read ${front_headphone_jack_mixer_name}"
		return 1  # treat as empty so we do not apply CTIA blindly
	else
		:
	fi
	if jack_control_text="$(
		"${amixer_executable}" -c "${alsa_card_number}" cget \
			"iface=CARD,name='${front_headphone_jack_mixer_name}'" \
			2>/dev/null
	)"; then
		if [[ "${jack_control_text}" == *"${front_headphone_jack_values_on}"* ]]; then
			return 0  # combo jack has a plug
		elif [[ "${jack_control_text}" == *"${front_headphone_jack_values_off}"* ]]; then
			return 1  # combo jack is empty
		else
			log_error "${front_headphone_jack_mixer_name} on card ${alsa_card_number} has no values=on/off: ${jack_control_text}"
			return 1  # treat as empty
		fi
	else
		log_error "amixer cannot read ${front_headphone_jack_mixer_name} on card ${alsa_card_number}"
		return 1  # treat as empty
	fi
}

# If the headphone jack is present, apply CTIA. If it is empty, apply
# unplugged UAJ. --watch re-runs this after a debounced jack change
# and when coef 0x45 drifts off CTIA while the jack stays in.
# Inputs: hwdep_device_path.
codec_apply_headset_jack_mode() {
	local hwdep_device_path="$1"
	if codec_headphone_jack_is_present "${hwdep_device_path}"; then
		log_info "${front_headphone_jack_mixer_name} is on; CTIA plugged headset mode"
		codec_apply_alc255_ctia_headset_mode "${hwdep_device_path}"
	else
		log_info "${front_headphone_jack_mixer_name} is off; unplugged UAJ"
		codec_apply_alc255_unplugged_headset_mode "${hwdep_device_path}"
	fi
}

# Raise pin 0x19 Amp-In to the maximum step. Without a Capture mixer
# this boost never appears in alsamixer. Inputs: hwdep_device_path.
codec_boost_headset_microphone_pin_amp() {
	local hwdep_device_path="$1"
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${headset_microphone_node}" \
		"${amp_gain_mute_set_verb}" \
		"${headset_microphone_pin_amp_boost_payload}" \
		>/dev/null
	log_info "Boosted pin ${headset_microphone_node} Amp-In to payload ${headset_microphone_pin_amp_boost_payload}"
}

# Set pin 0x19 to IN plus VREF_80 and print the GET Pin-ctls. Does not
# exit when GET is VREF_HIZ: unplugged UAJ gates MIC2 Vref and the
# codec then reports 0x20. Call codec_enable_headset_microphone_pin
# after CTIA so GET can stay 0x24. Inputs: hwdep_device_path.
# Output: GET Pin-ctls integer on stdout.
codec_write_headset_microphone_pin_in_vref80() {
	local hwdep_device_path="$1"
	local pin_control_value
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${headset_microphone_node}" \
		"${pin_widget_control_set_verb}" \
		"${pin_widget_control_in_vref80}" \
		>/dev/null
	pin_control_value="$(
		codec_write_hda_verb \
			"${hwdep_device_path}" \
			"${headset_microphone_node}" \
			"${pin_widget_control_get_verb}" \
			"0x0"
	)"
	echo "${pin_control_value}"
	return 0  # GET Pin-ctls after SET IN+VREF_80
}

# Set pin 0x19 to IN plus VREF_80 and require the GET to match.
# Call this after CTIA so MIC2 Vref is ungated. Inputs:
# hwdep_device_path.
codec_enable_headset_microphone_pin() {
	local hwdep_device_path="$1"
	local pin_control_value
	pin_control_value="$(
		codec_write_headset_microphone_pin_in_vref80 \
			"${hwdep_device_path}"
	)"
	if (( pin_control_value == pin_widget_control_in_vref80 )); then
		log_info "Pin ${headset_microphone_node} Pin-ctls=${pin_control_value} (IN VREF_80)"
		return 0  # pin 0x19 is IN plus VREF_80 after CTIA
	else
		log_error "Pin ${headset_microphone_node} Pin-ctls=${pin_control_value}, expected ${pin_widget_control_in_vref80}"
		exit 1
	fi
}

# Put the headset-mic pin, unused headphone-mic pin, headphone
# jack-detect pin, both ADC mixers, and both analog ADCs in D0.
# Inputs: hwdep_device_path.
codec_power_up_headset_microphone_path() {
	local hwdep_device_path="$1"
	local powered_widget_node
	for powered_widget_node in \
		"${headset_microphone_node}" \
		"${headphone_microphone_node}" \
		"${headphone_node}" \
		"${adc_mixer_node_primary}" \
		"${adc_mixer_node_secondary}" \
		"${adc_node_primary}" \
		"${adc_node_secondary}"
	do
		codec_write_hda_verb \
			"${hwdep_device_path}" \
			"${powered_widget_node}" \
			"${power_state_set_verb}" \
			"${power_state_d0}" \
			>/dev/null
	done
	log_info "Powered analog headset-mic widgets to D0"
}

# Unmute both analog ADC input amps at the +12 dB offset (payload
# adc_unmute_payload). Inputs: hwdep_device_path.
codec_unmute_analog_adcs() {
	local hwdep_device_path="$1"
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${adc_node_primary}" \
		"${amp_gain_mute_set_verb}" \
		"${adc_unmute_payload}" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${adc_node_secondary}" \
		"${amp_gain_mute_set_verb}" \
		"${adc_unmute_payload}" \
		>/dev/null
	log_info "Unmuted analog ADCs ${adc_node_primary} and ${adc_node_secondary} at payload ${adc_unmute_payload}"
}

# Unmute mixer index 1 (pin 0x19) on both ADC muxes and mute index 2
# (pin 0x1a) so leftover mic-in cannot keep the headphone-mic in the
# mix. Inputs: hwdep_device_path.
codec_unmute_headset_microphone_mixers() {
	local hwdep_device_path="$1"
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${adc_mixer_node_primary}" \
		"${amp_gain_mute_set_verb}" \
		"${headset_microphone_mixer_unmute_payload}" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${adc_mixer_node_secondary}" \
		"${amp_gain_mute_set_verb}" \
		"${headset_microphone_mixer_unmute_payload}" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${adc_mixer_node_primary}" \
		"${amp_gain_mute_set_verb}" \
		"${headphone_microphone_mixer_mute_payload}" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${adc_mixer_node_secondary}" \
		"${amp_gain_mute_set_verb}" \
		"${headphone_microphone_mixer_mute_payload}" \
		>/dev/null
	log_info "Unmuted ADC mixers ${adc_mixer_node_primary} and ${adc_mixer_node_secondary} index 1 (pin ${headset_microphone_node}); muted index 2 (pin ${headphone_microphone_node})"
}

# Write SET_CONFIG_DEFAULT 0x03a11130 on pin 0x19 (headset mic, no
# presence). The kernel pin-default cache may still show the BIOS
# 0x411111f0 in /proc; the hardware register is what UAJ uses.
# Inputs: hwdep_device_path.
codec_write_headset_microphone_pin_default() {
	local hwdep_device_path="$1"
	local pin_default_value
	local pin_default_byte0
	local pin_default_byte1
	local pin_default_byte2
	local pin_default_byte3
	local pin_default_readback
	pin_default_value=$((headset_microphone_pin_default))
	pin_default_byte0=$((pin_default_value & 0xff))
	pin_default_byte1=$(((pin_default_value >> 8) & 0xff))
	pin_default_byte2=$(((pin_default_value >> 16) & 0xff))
	pin_default_byte3=$(((pin_default_value >> 24) & 0xff))
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${headset_microphone_node}" \
		"${pin_config_default_bytes0_set_verb}" \
		"$(printf '0x%x' "${pin_default_byte0}")" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${headset_microphone_node}" \
		"${pin_config_default_bytes1_set_verb}" \
		"$(printf '0x%x' "${pin_default_byte1}")" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${headset_microphone_node}" \
		"${pin_config_default_bytes2_set_verb}" \
		"$(printf '0x%x' "${pin_default_byte2}")" \
		>/dev/null
	codec_write_hda_verb \
		"${hwdep_device_path}" \
		"${headset_microphone_node}" \
		"${pin_config_default_bytes3_set_verb}" \
		"$(printf '0x%x' "${pin_default_byte3}")" \
		>/dev/null
	pin_default_readback="$(
		codec_write_hda_verb \
			"${hwdep_device_path}" \
			"${headset_microphone_node}" \
			"${pin_config_default_get_verb}" \
			"0x0"
	)"
	log_info "Pin ${headset_microphone_node} SET_CONFIG_DEFAULT ${headset_microphone_pin_default}, GET=${pin_default_readback}"
}

# Program the analog headset-mic widgets and UAJ for the current jack
# state. Inputs: hwdep_device_path.
codec_program_headset_microphone_path() {
	local hwdep_device_path="$1"
	local pin_control_value
	codec_power_up_headset_microphone_path "${hwdep_device_path}"
	codec_write_headset_microphone_pin_default "${hwdep_device_path}"
	pin_control_value="$(
		codec_write_headset_microphone_pin_in_vref80 \
			"${hwdep_device_path}"
	)"
	log_info "Pin ${headset_microphone_node} SET ${pin_widget_control_in_vref80}, GET=${pin_control_value} before UAJ"
	codec_boost_headset_microphone_pin_amp "${hwdep_device_path}"
	codec_unmute_headset_microphone_mixers "${hwdep_device_path}"
	codec_unmute_analog_adcs "${hwdep_device_path}"
	codec_apply_alc255_default_jack_type "${hwdep_device_path}"
	sleep "${alc255_default_jack_type_settle_seconds}"
	codec_apply_headset_jack_mode "${hwdep_device_path}"
	if codec_headphone_jack_is_present "${hwdep_device_path}"; then
		codec_enable_headset_microphone_pin "${hwdep_device_path}"
	else
		pin_control_value="$(
			codec_write_hda_verb \
				"${hwdep_device_path}" \
				"${headset_microphone_node}" \
				"${pin_widget_control_get_verb}" \
				"0x0"
		)"
		if (( pin_control_value == pin_widget_control_in_vref_hiz )); then
			log_info "Pin ${headset_microphone_node} Pin-ctls=${pin_control_value} (IN VREF_HIZ) with empty jack; MIC2 Vref is gated until a 3-ring CTIA plug"
		elif (( pin_control_value == pin_widget_control_in_vref80 )); then
			log_info "Pin ${headset_microphone_node} Pin-ctls=${pin_control_value} (IN VREF_80) with empty jack"
		else
			log_info "Pin ${headset_microphone_node} Pin-ctls=${pin_control_value} with empty jack"
		fi
	fi
	log_info "Analog headset mic path enabled on ${hwdep_device_path} (pin ${headset_microphone_node})"
}

# Return 0 when vendor coef 0x45 is the CTIA plugged value. Silent so
# --watch can poll it. Inputs: hwdep_device_path.
codec_alc255_ctia_mode_is_active() {
	local hwdep_device_path="$1"
	local coefficient_45_value
	coefficient_45_value="$(
		codec_read_realtek_coef \
			"${hwdep_device_path}" \
			"${alc255_ctia_headset_mode_coef_index_45}"
	)"
	if (( coefficient_45_value == alc255_ctia_headset_mode_coef_value_45 )); then
		return 0  # UAJ is already CTIA
	else
		return 1  # UAJ drifted or is still unplugged
	fi
}

# Poll Front Headphone Jack. Debounce plug/unplug, then re-program UAJ.
# While the jack stays in, re-apply CTIA if coef 0x45 drifts (PipeWire
# restart, reboot with the mic already plugged). Does not return.
# Inputs: hwdep_device_path.
codec_watch_headphone_jack() {
	local hwdep_device_path="$1"
	local observed_jack_state=""
	local stable_jack_state=""
	local matching_poll_count=0
	local applied_jack_state=""
	if codec_headphone_jack_is_present "${hwdep_device_path}"; then
		observed_jack_state="present"
	else
		observed_jack_state="empty"
	fi
	stable_jack_state="${observed_jack_state}"
	applied_jack_state="${observed_jack_state}"
	matching_poll_count="${watch_jack_stable_polls}"
	log_info "Watching ${front_headphone_jack_mixer_name} (poll ${watch_jack_poll_seconds}s, debounce ${watch_jack_stable_polls} polls, initial ${stable_jack_state})"
	while true; do
		sleep "${watch_jack_poll_seconds}"
		if codec_headphone_jack_is_present "${hwdep_device_path}"; then
			observed_jack_state="present"
		else
			observed_jack_state="empty"
		fi
		if [[ "${observed_jack_state}" == "${stable_jack_state}" ]]; then
			if (( matching_poll_count < watch_jack_stable_polls )); then
				matching_poll_count=$((matching_poll_count + 1))
			else
				:
			fi
		else
			matching_poll_count=1
			stable_jack_state="${observed_jack_state}"
		fi
		if (( matching_poll_count >= watch_jack_stable_polls )); then
			if [[ "${stable_jack_state}" == "present" ]]; then
				if codec_alc255_ctia_mode_is_active "${hwdep_device_path}"; then
					:
				else
					log_info "Front Headphone jack present and UAJ is not CTIA; applying CTIA"
					codec_program_headset_microphone_path "${hwdep_device_path}"
					applied_jack_state="present"
				fi
			else
				if [[ "${applied_jack_state}" != "empty" ]]; then
					log_info "Front Headphone jack empty; applying unplugged UAJ"
					codec_program_headset_microphone_path "${hwdep_device_path}"
					applied_jack_state="empty"
				else
					:
				fi
			fi
		else
			:
		fi
	done
}

main "$@"
