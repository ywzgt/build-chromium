#!/bin/bash -ex

gcl() {
	git clone --depth=1 $*
}

_env() {
	case "$1" in
		macos-*|mac)
			HOST_OS=mac
			;;
		ubuntu-*|linux)
			HOST_OS=linux
			;;
		windows-*|win)
			HOST_OS=windows
			;;
	esac

	ARCH="$2"
	case "$(uname -m)" in
		x86_64)
			HOST_ARCH=amd64
			;;
		aarch64|arm64)
			HOST_ARCH=arm64
			;;
	esac

	TARGET="$3"
	case "$3" in
		android|cromite|cgms)
			TARGET_OS=android
			;;
		*)
			TARGET_OS="$3"
			;;
	esac

	NINJA_STATUS="[%r %f/%t %es] "
	cat>>env.sh<<-EOF
		ARCH=$ARCH
		HOST_OS=$HOST_OS
		HOST_ARCH=$HOST_ARCH
		TARGET=$TARGET
		TARGET_OS=$TARGET_OS
		VER=$(<VERSION)
		PATH=$PWD/src/run_bin:$PWD/depot_tools:$PATH
		DEPOT_TOOLS_UPDATE=0
		NINJA_STATUS=$NINJA_STATUS
	EOF
	cat env.sh >> $GITHUB_ENV
}

prepare() {
	_env $*
	git config --global user.name 'github-actions'
	git config --global user.email 'noreply@github.com'

	local CIPD_URL="https://chrome-infra-packages.appspot.com/dl"
# 	wget -nv -O gn.zip "$CIPD_URL/gn/gn/${HOST_OS}-${HOST_ARCH}/+/latest"
# 	unzip -d bin gn.zip 'gn*'
	wget -nv -O ninja.zip "$CIPD_URL/infra/3pp/tools/ninja/${HOST_OS}-${HOST_ARCH}/+/latest"
	unzip -d bin ninja.zip 'ninja*'
	wget -nv -O python3.zip "$CIPD_URL/infra/3pp/tools/cpython3/${HOST_OS}-${HOST_ARCH}/+/latest"
	unzip -q python3.zip
	mv install-build-dep.sh bin/

	if [[ $HOST_OS == mac ]]; then
		brew install coreutils gnu-sed
		local _path
		if [[ $HOST_ARCH = arm64 ]]; then
			_path="/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/gnu-sed/libexec/gnubin"
		else
			_path="/usr/local/opt/gnu-sed/libexec/gnubin"
		fi
		echo "PATH=$PWD/bin:$PWD/depot_tools:${_path}:$PATH" >> $GITHUB_ENV
		sudo mdutil -a -i off  #Disable Spotlight
	elif [[ $HOST_OS == linux ]]; then
		local dir="${PWD##*/}"
		sudo chown "$UID:$(id -g)" /mnt
		mv "../$dir" /mnt
		ln -sv "/mnt/$dir" ..
	fi
	git pull origin "$GITHUB_REF" || true
}

fetch_src() {
	cat >.gclient<<EOF
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
  },
]
target_os = [ '${TARGET_OS}' ]
EOF

	if [[ $TARGET_OS = linux ]] || [[ $TARGET_OS = mac ]]; then
		sed -i '/target_os/d' .gclient
	fi

	gcl https://chromium.googlesource.com/chromium/tools/depot_tools.git
	gcl https://github.com/chromium/chromium.git -b "$VER" src
	cat src/chrome/VERSION
	mv bin src/run_bin

	local patches_url="https://github.com/$GITHUB_ACTOR/chromium-patches"
	if ! gcl "$patches_url" -b "${VER%.*}".x; then
		gcl "$patches_url"
	fi
}

rsync_src(){
	cd src

	local PATCHES=()
	case "$TARGET" in
		android)
			PATCHES=(`cat ../chromium-patches/gms_patches.txt`)
			;;
		cromite)
			PATCHES=(`cat ../chromium-patches/cromite_patches.txt`)
			;;
		cgms)
			PATCHES=(`cat ../chromium-patches/cromite_gms_patches.txt`)
			(cd ../chromium-patches/patches; patch -p1 -i Edit-cromite-flags-support-patch.diff)
			;;
		linux|mac)
			PATCHES=(`cat ../chromium-patches/desktop_patches.txt`)
			;;
		win)
			PATCHES=(`cat ../chromium-patches/win_patches.txt` `cat ../chromium-patches/desktop_patches.txt`)
			;;
	esac

	_patch() {
		local f="../chromium-patches/patches/$1"
		 if ! grep -q 'GIT binary patch'  $f; then
			patch -Np1 -i $f
			git add $(grep '^+++ b/' $f | sed 's/^+++ b\///')
			git commit -qm "Add patch: $1"
		else
			git am $f
		fi
	}

	if [[ -n ${PATCHES[*]} ]]; then
		for i in ${PATCHES[*]}; do _patch $i; done
		find . -name \*.orig -delete
		case "$TARGET" in
			cromite)
				sed -i '1i#include "base/strings/string_util.h"' components/user_scripts/browser/user_script_prefs.cc
				sed -i '/^package org.chromium.chrome.browser.privacy.settings;$/a\import android.content.SharedPreferences;\nimport org.chromium.base.ContextUtils;' chrome/android/java/src/org/chromium/chrome/browser/privacy/settings/PrivacySettings.java
				;;
			cgms)
				sed -i '1i#include "base/strings/string_util.h"' components/user_scripts/browser/user_script_prefs.cc
				;;
		esac
		if [ -f components/adblock/core/resources/update.sh ]; then
			(cd components/adblock/core/resources; bash update.sh)
		fi
	fi

	gclient sync --no-history --nohooks
	build/util/lastchange.py -o build/util/LASTCHANGE
	build/util/lastchange.py -m GPU_LISTS_VERSION --revision-id-only --header gpu/config/gpu_lists_version.h
	build/util/lastchange.py -m SKIA_COMMIT_HASH -s third_party/skia --header skia/ext/skia_commit_hash.h
	build/util/lastchange.py -s third_party/dawn --revision gpu/webgpu/DAWN_VERSION
	download_from_google_storage.py --no_resume --extract --bucket chromium-nodejs -s third_party/node/node_modules.tar.gz.sha1
	python3 tools/download_optimization_profile.py --newest_state=chrome/android/profiles/newest.txt --local_state=chrome/android/profiles/local.txt --output_name=chrome/android/profiles/afdo.prof --gs_url_base=chromeos-prebuilt/afdo-job/llvm

	if [[ $TARGET_OS = linux ]]; then
		sed -i 's/-${CHANNEL}//' chrome/installer/linux/debian/build.sh
		sed -i '/^Package:/s/-@@CHANNEL@@//' chrome/installer/linux/debian/control.template
		python3 build/linux/sysroot_scripts/install-sysroot.py --arch=$ARCH
	fi
	python3 tools/clang/scripts/update.py
	python3 tools/rust/update_rust.py; rm -rf "$HOME/.cargo/"

	if [[ $HOST_OS != windows ]]; then
		sed -i '/^update_win$/d' third_party/node/update_node_binaries
		if [[ $HOST_OS = linux ]]; then
			sed -i '/^update_unix.*darwin-/d' third_party/node/update_node_binaries
		else
			sed -i '/^update_unix.*linux/d' third_party/node/update_node_binaries
			if [[ $HOST_ARCH = arm64 ]]; then
				sed -i '/^update_unix.*darwin-x64/d' third_party/node/update_node_binaries
			else
				sed -i '/^update_unix.*darwin-arm64/d' third_party/node/update_node_binaries
			fi
		fi
	else
		sed -i '/^update_unix\s/d' third_party/node/update_node_binaries
	fi
	sed -i '/ wget -P /s/wget/& -nv/' third_party/node/update_node_binaries
	third_party/node/update_node_binaries

	if [[ $TARGET_OS != android ]]; then
		local pgo_target
		if [[ $TARGET_OS = win ]]; then
			if [[ $ARCH != arm64 ]]; then
				local _arch=${ARCH/86/32}
				pgo_target=win${_arch#x}
			else
				pgo_target=win-$ARCH
			fi
		elif [[ $TARGET_OS = linux ]]; then
			pgo_target=linux
		else
			pgo_target=mac
		fi
		tools/update_pgo_profiles.py --target=$pgo_target update --gs-url-base=chromium-optimization-profiles/pgo_profiles
		ln -sv ../../../depot_tools v8/third_party
		v8/tools/builtins-pgo/download_profiles.py download
		[[ $HOST_OS != mac ]] || download_from_google_storage.py --no_resume --bucket chromium-browser-clang -s tools/clang/dsymutil/bin/dsymutil.${HOST_ARCH/amd/x}.sha1 -o tools/clang/dsymutil/bin/dsymutil
	fi

	update_winsdk() {
		TOOLCHAIN_HASH=`grep '^TOOLCHAIN_HASH' build/vs_toolchain.py | cut -d= -f2 | sed "s/'\|\s//g"`
		SDK_VERSION=`grep '^SDK_VERSION' build/vs_toolchain.py | cut -d= -f2 | sed "s/'\|\s//g"`
		DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL="https://github.com/$GITHUB_ACTOR/winsdk/releases/latest/download/"
		wget -q "https://api.github.com/repos/$GITHUB_ACTOR/winsdk/releases" "${DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL}MSVS_HASH"
		local vs_hash="$(cut -d' ' -f1 MSVS_HASH)"
		local sdk_ver="$(cut -d' ' -f3 MSVS_HASH)"
		if [[ $SDK_VERSION != $sdk_ver ]]; then
			local url="$(grep browser_download_url releases | grep $SDK_VERSION | sed 's/\s\+//g;/VisualStudio\|MSVS_HASH/d' | cut -d\" -f4 | head -1)"
			DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL="${url%/*}/"
			vs_hash="$(echo ${url##*/} | sed 's/\.zip//')"
		fi
		export DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL
		export GYP_MSVS_HASH_${TOOLCHAIN_HASH}="$vs_hash"
	}

	if [[ $TARGET_OS = win ]] && [[ $HOST_OS != windows ]]; then
		[[ $HOST_OS = mac ]] || sudo apt install -y gperf libfuse2
		download_from_google_storage.py --no_resume --bucket chromium-browser-clang/rc -s build/toolchain/win/rc/linux64/rc.sha1
		download_from_google_storage.py --no_resume --bucket chromium-browser-clang/rc -s build/toolchain/win/rc/mac/rc.sha1
		download_from_google_storage.py --no_resume --bucket chromium-browser-clang/ciopfs -s build/ciopfs.sha1
		update_winsdk
		python3 build/vs_toolchain.py update --force
	fi

	local cl="$PWD/third_party/llvm-build/Release+Asserts/bin/clang"
	local gn_version="$(sed -n 's/.*gn_version.*git_revision:\(.*\).,/\1/p' DEPS)"
	git clone https://gn.googlesource.com/gn -b main
	cd gn
	git checkout --quiet "${gn_version}"
	CXX="${cl}++" CC="$cl" build/gen.py
	ninja -C out
	install -m755 out/gn -t ../run_bin
	rm -rf .git
}

install-dep() {
	local _args
	if [[ "$TARGET_OS" = android ]]; then
		_args="--android"
	elif [[ $ARCH = arm* ]]; then
		_args="--arm"
	fi
	case "$TARGET_OS" in
		android|linux)
			install-build-dep.sh $_args
			;;
		win)
			if [[ $HOST_OS = linux ]]; then
				sudo apt install -y gperf libfuse2
				local toolchain_dir="src/third_party/depot_tools/win_toolchain/vs_files"
				if ! mountpoint -q "${toolchain_dir}"; then
					src/build/ciopfs -o use_ino ${toolchain_dir}.ciopfs ${toolchain_dir}
				fi
			fi
			;;
	esac
}

build-chrome() {
	cd src
	local build_dir="out/${TARGET}_${ARCH}"
	if [ ! -d "$build_dir" ]; then
		../args.sh "$TARGET_OS" "$ARCH" "$build_dir"
		gn gen "$build_dir"
	fi

	_exit() {
		local a=$?
		if [ -f "../in_building" ]; then
			return $a
		else
			exit 0
		fi
	}

	_retry() {
		if [[ ${TARGET_OS} = android ]] && [ -f "../in_building" ]; then
			ninja -C "$build_dir" ${targets[*]} || _exit
		else
			_exit
		fi
	}

	_rust_prebuild() {
		sleep 1
		ninja -C "$build_dir" \
			build/rust/chromium_prelude || _rust_prebuild
	}

	touch ../in_building
	sleep 18000 && rm ../in_building && pkill -9 ninja &

	local targets=()
	local pre_targets=()
	case "$TARGET_OS" in
		android)
			targets=(chrome_public_{apk,bundle})
			if [[ $ARCH = *64 ]] && [[ $TARGET != cgms ]]; then
				targets+=(
					system_webview_{apk,bundle}
					monochrome_public_bundle
					trichrome_chrome_bundle  #only bundle
					trichrome_library_apk  #only apk
					trichrome_webview_bundle  #or apk
				)
			fi
			pre_targets=(
				components/page_image_service/mojom:mojo_bindings
				chrome/browser/resource_coordinator:mojo_bindings
				chrome/browser/page_info:page_info_buildflags
			)
			if [[ $TARGET != android ]]; then
				pre_targets+=(components/content_settings/core/common:bromite_content_settings)
				if ! grep -q org.chromium.cromite "$build_dir/args.gn"; then
					sed -i '/chrome_public_manifest_package/s/=.*/= "org.chromium.cromite"/' "$build_dir/args.gn"
				 fi
			fi
			;;
		linux)
			targets=(chrome/installer/linux:stable_deb)
			;;
		win)
			targets=(mini_installer)
			;;
	esac

	echo "status=running" >> $GITHUB_OUTPUT

	case "$TARGET_OS" in linux|mac|win)
		pre_targets=(printing/{mojom:printing_context,backend/mojom:mojom}_headers) ;;
	esac

	[[ $TARGET_OS-$1 != win-pre ]] || _rust_prebuild
	if [ "$1" = "pre" ] && [ -n "$pre_targets" ]; then
		ninja -C "$build_dir" ${pre_targets[*]} || _exit
		local pre_target_file=(
			chrome/browser/page_info/page_info_buildflags.h
			chrome/browser/resource_coordinator/lifecycle_unit_state.mojom{,-forward,-features,-shared{,-internal}}.h
			components/page_image_service/mojom/page_image_service.mojom{,-{features,shared{,-internal},forward}}.h
			components/content_settings/core/common/bromite_content_settings.inc
			printing/mojom/printing_context.mojom-shared-internal.h
		)
		for f in ${pre_target_file[@]}; do
			[[ ${TARGET_OS} != android ]] || local _p="android_"
			if [ -f "$build_dir/gen/$f" ] && [ ! -f "$build_dir/${_p}clang_${ARCH}/gen/$f" ]
			then
				mkdir -p "$build_dir/${_p}clang_${ARCH}/gen/${f%/*}"
				cp -a "$build_dir/gen/$f" "$build_dir/${_p}clang_${ARCH}/gen/$f"
				if [[ ${TARGET_OS}-${ARCH} = android-*64 ]]; then
					local _arch=${ARCH%64}
					_arch=${_arch/x/x86}
					mkdir -p "$build_dir/android_clang_${_arch}/gen/${f%/*}"
					cp -a "$build_dir/gen/$f" "$build_dir/android_clang_${_arch}/gen/$f"
				fi
			fi
		done
	fi
	ninja -C "$build_dir" ${targets[*]:-chrome} || _retry
	echo "status=finished" >> $GITHUB_OUTPUT

	if [[ $TARGET_OS-$ARCH = android-*64 ]]; then
		rm -rf "$build_dir/apks/"monochrome*.aab
		sed -i '/chrome_public_manifest_package/s/=.*/= "com.android.webview"/' "$build_dir/args.gn"
		ninja -C "$build_dir" monochrome_public_bundle
	fi
}

pack_cache() {
	rm -rf src/.git
	local toolchain_dir="src/third_party/depot_tools/win_toolchain/vs_files"
	if [[ $HOST_OS-$TARGET = linux-win ]] && mountpoint -q "${toolchain_dir}"; then
		umount -v $toolchain_dir || umount -lv $toolchain_dir
	fi
	tar cf - src | zstd -vv -12 -T0 -o build_cache-$VER-$TARGET-$ARCH.tar.zst
}

unpack_cache() {
	local f="build_cache-$VER-$TARGET-$ARCH.tar.zst"
	echo "Extracting the $f..."
	tar xf $f && ls -lh $f && rm -f $f
}

pack_release() {
	local DEST="$PWD/release"
	local build_dir="src/out/${TARGET}_${ARCH}"
	mkdir -p "$DEST"
	case "$TARGET_OS" in
		android)
			local f suffix
			[[ $TARGET != cgms ]] || TARGET=cromite_gms
			[[ $TARGET = android ]] || suffix="_${TARGET}"
			mv -v $build_dir/apks/*.a{ab,pk} "$DEST"
			cd "$DEST"
			for i in *; do
				f="${ARCH}_${i%.*}${suffix}.${i##*.}"
				mv $i "$f"
				[[ $f != *.apk ]] || xz -9 -vT0 "$f"
			done
			ls -la
			;;
		linux)
			mv -v $build_dir/*.deb "$DEST"
			;;
		mac)
			cd "$build_dir"
			xattr -rc Chromium.app
			sudo chown -R 0:0 Chromium.app
			sudo tar cf - Chromium.app | xz -T0 > "$DEST/"Chromium.app-$ARCH.tar.xz
			;;
		win)
			mv -v $build_dir/mini_installer.exe "$DEST/mini_installer-$ARCH.exe"
			;;
	esac
}

case "$1" in
	prepare|pre)
		shift
		prepare $*
		;;
	fetch-sources)
		fetch_src
		rsync_src
		;;
	install-dep)
		install-dep
		;;
	build)
		build-chrome $2
		;;
	pack)
		pack_$2
		;;
	unpack)
		unpack_$2
		;;
	list_args)
		cd src
		[[ $ARCH = *64 ]] || exit 0
		if [[ $HOST_OS-$TARGET = linux-win ]]; then
			build/ciopfs -o use_ino third_party/depot_tools/win_toolchain/vs_files{.ciopfs,}
		fi
		echo "upload=yes" >> $GITHUB_OUTPUT
		gn ls "out/${TARGET}_${ARCH}" > ../targets-${TARGET}_${ARCH}.txt
		gn args "out/${TARGET}_${ARCH}"  --list > ../args-${TARGET}_${ARCH}.txt
		gn args "out/${TARGET}_${ARCH}"  --list --short | tee -a ../args-short-${TARGET}_${ARCH}.txt
		;;
esac
