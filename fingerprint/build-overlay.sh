#!/usr/bin/env bash
# Build an overlay libfprint that contains the press-mode egis0570 driver.
#
# Clones or reuses libfprint 1.94.10, copies this repo's driver over the
# in-tree swipe driver, and writes libfprint-2.so plus the capture tool
# into fingerprint/dist/. Does not touch the ostree /usr tree.

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- libfprint source ---
libfprint_git_url="https://gitlab.freedesktop.org/libfprint/libfprint.git"
libfprint_git_tag="v1.94.10"
libfprint_source_directory="/tmp/sf514-fp/libfprint"
libfprint_build_directory="/tmp/sf514-fp/libfprint-build"

# --- Meson options: only the pad this laptop has, no docs or tests ---
meson_prefix_directory="/usr/local"
meson_libdir_name="lib64"

# =============================================================================
# LOGGER
# =============================================================================

# Print an error line to stderr.
log_error() {
	local log_message="$1"
	echo "sf514-fp-build: ${log_message}" >&2
}

# Print an informational line to stdout.
log_info() {
	local log_message="$1"
	echo "sf514-fp-build: ${log_message}"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Resolve the repo, ensure libfprint sources, overlay the driver, build,
# and copy artifacts into fingerprint/dist. Exits 0 on success.
main() {
	path_resolve_repository_root
	source_ensure_libfprint_checkout
	overlay_copy_driver_sources
	overlay_patch_meson_driver_list
	build_configure_meson
	build_compile_ninja
	dist_copy_artifacts
	log_info "Overlay library is in ${repository_root_directory}/fingerprint/dist/lib64"
	log_info "Next: sudo ./scripts-fingerprint-fix/install.sh"
}

# =============================================================================
# BUILD
# =============================================================================

# Run ninja in the meson build directory.
build_compile_ninja() {
	if ninja -C "${libfprint_build_directory}"; then
		log_info "ninja finished"
		return 0  # library built
	else
		log_error "ninja failed"
		exit 1
	fi
}

# Configure meson with prefix /usr/local and only the egis0570 driver.
build_configure_meson() {
	if [[ -f "${libfprint_build_directory}/build.ninja" ]]; then
		log_info "Reusing meson build directory ${libfprint_build_directory}"
		meson setup --reconfigure \
			"${libfprint_build_directory}" \
			"${libfprint_source_directory}" \
			--prefix="${meson_prefix_directory}" \
			--libdir="${meson_libdir_name}" \
			-Ddrivers=egis0570 \
			-Dintrospection=false \
			-Ddoc=false \
			-Dgtk-examples=false \
			-Dinstalled-tests=false \
			-Dudev_rules=disabled \
			-Dudev_hwdb=disabled
		return 0  # reconfigured
	else
		rm -rf "${libfprint_build_directory}"
		meson setup \
			"${libfprint_build_directory}" \
			"${libfprint_source_directory}" \
			--prefix="${meson_prefix_directory}" \
			--libdir="${meson_libdir_name}" \
			-Ddrivers=egis0570 \
			-Dintrospection=false \
			-Ddoc=false \
			-Dgtk-examples=false \
			-Dinstalled-tests=false \
			-Dudev_rules=disabled \
			-Dudev_hwdb=disabled
		return 0  # configured
	fi
}

# =============================================================================
# DIST
# =============================================================================

# Copy the built libfprint and the capture tool into fingerprint/dist.
dist_copy_artifacts() {
	local dist_lib_directory="${repository_root_directory}/fingerprint/dist/lib64"
	local dist_bin_directory="${repository_root_directory}/fingerprint/dist/bin"
	local built_library_path
	mkdir -p "${dist_lib_directory}" "${dist_bin_directory}"
	built_library_path="$(find "${libfprint_build_directory}" -name 'libfprint-2.so.2.0.0' | head -n 1)"
	if [[ -z "${built_library_path}" ]]; then
		log_error "Built libfprint-2.so.2.0.0 not found under ${libfprint_build_directory}"
		exit 1
	else
		cp -a "${built_library_path}" "${dist_lib_directory}/libfprint-2.so.2.0.0"
		ln -sfn libfprint-2.so.2.0.0 "${dist_lib_directory}/libfprint-2.so.2"
		ln -sfn libfprint-2.so.2 "${dist_lib_directory}/libfprint-2.so"
		log_info "Copied ${built_library_path}"
	fi
	if [[ -x "${repository_root_directory}/fingerprint/capture/sf514-egis0570-capture" ]]; then
		cp -a \
			"${repository_root_directory}/fingerprint/capture/sf514-egis0570-capture" \
			"${dist_bin_directory}/sf514-egis0570-capture"
	else
		log_info "Capture tool not built yet; run make in fingerprint/capture/"
	fi
	if [[ -x "${repository_root_directory}/fingerprint/overlay/sf514-egis0570-ridge-eval" ]]; then
		cp -a \
			"${repository_root_directory}/fingerprint/overlay/sf514-egis0570-ridge-eval" \
			"${dist_bin_directory}/sf514-egis0570-ridge-eval"
	else
		log_info "Matcher eval not built yet; run make -C fingerprint/overlay self-test"
	fi
}

# =============================================================================
# OVERLAY
# =============================================================================

# Replace in-tree egis0570 sources with this repo's press-mode driver.
overlay_copy_driver_sources() {
	cp -a \
		"${repository_root_directory}/fingerprint/overlay/egis0570.c" \
		"${libfprint_source_directory}/libfprint/drivers/egis0570.c"
	cp -a \
		"${repository_root_directory}/fingerprint/overlay/egis0570.h" \
		"${libfprint_source_directory}/libfprint/drivers/egis0570.h"
	cp -a \
		"${repository_root_directory}/fingerprint/overlay/egis0570-ridge.c" \
		"${libfprint_source_directory}/libfprint/drivers/egis0570-ridge.c"
	cp -a \
		"${repository_root_directory}/fingerprint/overlay/egis0570-ridge.h" \
		"${libfprint_source_directory}/libfprint/drivers/egis0570-ridge.h"
	log_info "Copied press-mode egis0570 sources into the libfprint tree"
}

# Point the egis0570 meson driver list at the ridge matcher source too.
overlay_patch_meson_driver_list() {
	local meson_file="${libfprint_source_directory}/libfprint/meson.build"
	if grep -q "drivers/egis0570-ridge.c" "${meson_file}"; then
		log_info "meson.build already lists egis0570-ridge.c"
		return 0  # already patched
	else
		python3 - "${meson_file}" <<'PY'
from pathlib import Path
import sys
meson_file = Path(sys.argv[1])
text = meson_file.read_text()
old = "    'egis0570' :\n        [ 'drivers/egis0570.c' ],"
new = "    'egis0570' :\n        [ 'drivers/egis0570.c', 'drivers/egis0570-ridge.c' ],"
if old not in text:
    raise SystemExit("Could not find egis0570 driver list in meson.build")
meson_file.write_text(text.replace(old, new, 1))
PY
		log_info "Patched ${meson_file} to compile egis0570-ridge.c"
		return 0  # patched
	fi
}

# =============================================================================
# PATH
# =============================================================================

# Set repository_root_directory to the directory that contains fingerprint/.
path_resolve_repository_root() {
	local script_directory
	script_directory="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
	repository_root_directory="$(cd "${script_directory}/.." && pwd)"
	if [[ -d "${repository_root_directory}/fingerprint/overlay" ]]; then
		return 0  # repo root resolved
	else
		log_error "Cannot find fingerprint/overlay under ${repository_root_directory}"
		exit 1
	fi
}

# =============================================================================
# SOURCE
# =============================================================================

# Clone libfprint 1.94.10 if the working copy is missing.
source_ensure_libfprint_checkout() {
	if [[ -d "${libfprint_source_directory}/libfprint/drivers" ]]; then
		log_info "Using existing libfprint checkout ${libfprint_source_directory}"
		return 0  # already cloned
	else
		mkdir -p "$(dirname "${libfprint_source_directory}")"
		if git clone --depth 1 --branch "${libfprint_git_tag}" \
			"${libfprint_git_url}" "${libfprint_source_directory}"; then
			log_info "Cloned ${libfprint_git_tag}"
			return 0  # cloned
		else
			log_error "git clone of libfprint failed"
			exit 1
		fi
	fi
}

# Global filled by path_resolve_repository_root.
repository_root_directory=""

main "$@"
