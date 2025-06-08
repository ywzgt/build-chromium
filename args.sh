#!/bin/bash -e

usage() {
	cat <<-EOF
		args.sh [OS] [Arch] [build DIR]
	EOF
	exit $*
}

if [ $# -lt 3 ]; then
	usage 1
fi

build_dir="$3"
mkdir -p "$build_dir"
cat >"$build_dir/args.gn"<<EOF
symbol_level = 0
blink_symbol_level = 0
is_official_build = true
is_debug = false
is_component_build = false
dcheck_always_on = false
disable_fieldtrial_testing_config = true
enable_updater = false
enable_av1_decoder = true
enable_dav1d_decoder = true
enable_mse_mpeg2ts_stream_parser = true
enable_hangout_services_extension = false
enable_iterator_debugging = false
enable_mdns = false
enable_nacl = false
enable_vr = false
enable_widevine = true
exclude_unwind_tables = true
ffmpeg_branding = "Chrome"
proprietary_codecs = true
google_api_key = "aizasyduovftsgo8saxrmqkic90attzypjjnklc"
google_default_client_id = "77185425430.apps.googleusercontent.com"
google_default_client_secret = "OTJgUOQcT7lO7GsGZq2G4IlT"
icu_use_data_file = true
include_both_v8_snapshots = false
rtc_build_examples = false
treat_warnings_as_errors = false
use_rtti = false
use_unofficial_version_number = false
EOF

args_android() {
	cat >>"$build_dir/args.gn"<<-EOF
		is_java_debug = false
		android_channel = "stable"
		chrome_pgo_phase = 0
		debuggable_apks = false
		dfmify_dev_ui = false
		disable_android_lint = true
		enable_arcore = false
		enable_cardboard = false
		enable_openxr = false
		use_errorprone_java_compiler = false
		chrome_public_manifest_package = "org.chromium.browser"
	EOF
}

args_mac() {
	cat >>"$build_dir/args.gn"<<-EOF
		is_clang = true
		fatal_linker_warnings = false
	EOF
}

args_win() {
	cat >>"$build_dir/args.gn"<<-EOF
		use_debug_fission = true
	EOF
}

case "$1" in
	android)
		args_android
		;;
	mac)
		args_mac
		;;
	win)
		args_win
		;;
esac

cat >>"$build_dir/args.gn"<<EOF
target_os = "$1"
target_cpu = "$2"
EOF
