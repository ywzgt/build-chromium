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

	BLD_TARGET="$3"
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
		BLD_TARGET=$BLD_TARGET
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
		echo "PATH=$PWD/src/run_bin:$PWD/depot_tools:${_path}:$PATH" >> $GITHUB_ENV
		sudo mdutil -a -i off  #Disable Spotlight
	elif [[ $HOST_OS == linux ]]; then
		local dir="${PWD##*/}"
		sudo chown "$UID:$(id -g)" /mnt
		cd ..
		mv "$dir" /mnt && ln -sv "/mnt/$dir" .
		cd "$dir"
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
    "custom_vars": { "checkout_configuration": "small" },
  },
]
target_os = [ '${TARGET_OS}' ]
EOF

	if [[ $TARGET_OS = linux ]] || [[ $TARGET_OS = mac ]]; then
		sed -i '/target_os/d' .gclient
	fi
	rm -rf src
	gcl https://chromium.googlesource.com/chromium/tools/depot_tools.git
	gcl https://github.com/chromium/chromium.git -b "$VER" src
	cat src/chrome/VERSION
	mv bin src/run_bin && mv lib src/

	local patches_url="https://github.com/$GITHUB_ACTOR/chromium-patches"
	local patches_ver="${VER%.*}.x"
	if git ls-remote --exit-code --tags --refs "$patches_url" "refs/tags/$VER" >/dev/null 2>&1
	then patches_ver="$VER"; fi
	if ! gcl "$patches_url" -b "$patches_ver"; then
		gcl "$patches_url"
	fi
}

rsync_src(){
	cd src

	local PATCHES=()
	local PATCH_DIR="../chromium-patches"
	case "$BLD_TARGET" in
		android)
			PATCHES=(`cat $PATCH_DIR/gms_patches.txt`)
			;;
		cromite)
			PATCHES=(`cat $PATCH_DIR/cromite_patches.txt`)
			;;
		cgms)
			PATCHES=(`cat $PATCH_DIR/cromite_gms_patches.txt`)
			;;
		linux|mac)
			PATCHES=(`cat $PATCH_DIR/desktop_patches.txt`)
			;;
		win)
			PATCHES=(`cat $PATCH_DIR/win_patches.txt` `cat $PATCH_DIR/desktop_patches.txt`)
			;;
	esac

	_patch() {
		local f="$PATCH_DIR/patches/$1"
		 if ! grep -q 'GIT binary patch'  $f; then
			if patch --dry-run -Np1 -i $f >/dev/null; then
				patch -Np1 -i $f
				git add $(grep '^+++ b/' $f | sed 's/^+++ b\///')
				git commit -qm "Add patch: $1"
			else
				echo ":: SKIP PATCH: $f"
			fi
		else
			git am $f
		fi
	}

	if [[ -n ${PATCHES[*]} ]]; then
		for i in ${PATCHES[*]}; do _patch $i; done
		find . -name \*.orig -delete
		if [ -f components/adblock/core/resources/update.sh ]; then
			(cd components/adblock/core/resources; bash update.sh)
		fi
	fi

	gclient sync --no-history --nohooks
	build/util/lastchange.py -o build/util/LASTCHANGE
	build/util/lastchange.py -m GPU_LISTS_VERSION --revision-id-only --header gpu/config/gpu_lists_version.h
	build/util/lastchange.py -m SKIA_COMMIT_HASH -s third_party/skia --header skia/ext/skia_commit_hash.h
	build/util/lastchange.py -s third_party/dawn --revision gpu/webgpu/DAWN_VERSION
	python3 tools/download_optimization_profile.py --newest_state=chrome/android/profiles/newest.txt --local_state=chrome/android/profiles/local.txt --output_name=chrome/android/profiles/afdo.prof --gs_url_base=chromeos-prebuilt/afdo-job/llvm

	if [[ $TARGET_OS = linux ]]; then
		for p in debian rpm; do
			local f=chrome/installer/linux/$p/build
			[ ! -f "$f.sh" ] || sed -i 's/-${CHANNEL}//' $f.sh
			[ ! -f "$f.py" ] || sed -i 's/-{config.channel}//' $f.py
		done
		sed -i '/^Package:/s/-@@CHANNEL@@\|-@@channel//g' chrome/installer/linux/debian/control.template
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
			[[ $ARCH = x64 ]] || pgo_target=mac-arm
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
	[[ $HOST_OS = mac ]] || export CXX="${cl}++" CC="$cl"
	build/gen.py
	ninja -C out -v
	install -m755 out/gn ../run_bin/
	rm -rf .git; unset CC CXX
}

install-dep() {
	local _args
	if [[ $TARGET_OS = android ]]; then
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
	local build_dir="out/${BLD_TARGET}_${ARCH}"
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
			targets=(chrome_public_apk)
			if [[ $ARCH = *64 ]] && [[ $BLD_TARGET != cgms ]]; then
				targets+=(
					chrome_public_bundle
					system_webview_bundle
					monochrome_public_bundle
					trichrome_chrome_bundle  #only bundle
					trichrome_library_apk  #only apk
					trichrome_webview_bundle  #or apk
				)
			fi
			if [[ $BLD_TARGET != android ]]; then
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
	[[ $TARGET_OS-$1 != win-pre ]] || _rust_prebuild
	if [ "$1" = "pre" ] && [ -n "$pre_targets" ]; then
		ninja -C "$build_dir" ${pre_targets[*]} || _exit
	fi
	ninja -C "$build_dir" ${targets[*]:-chrome} || _retry

	if [[ $TARGET_OS-$ARCH = android-*64 ]] && [[ $BLD_TARGET != cgms ]]; then
		rm -rf "$build_dir/apks/"monochrome*.aab
		sed -i '/chrome_public_manifest_package/s/=.*/= "com.android.webview"/' "$build_dir/args.gn"
		ninja -C "$build_dir" monochrome_public_bundle || _retry
	fi
	echo "status=finished" >> $GITHUB_OUTPUT
}

pack_cache() {
	rm -rf src/.git
	local toolchain_dir="src/third_party/depot_tools/win_toolchain/vs_files"
	if [[ $HOST_OS-$BLD_TARGET = linux-win ]] && mountpoint -q "${toolchain_dir}"; then
		umount -v $toolchain_dir || umount -lv $toolchain_dir
	fi
	rm -f build_cache-$VER-${BLD_TARGET}-$ARCH.tar.zst
	tar cf - src | zstd -vv -12 -T0 -o build_cache-$VER-${BLD_TARGET}-$ARCH.tar.zst
}

unpack_cache() {
	local f="build_cache-$VER-${BLD_TARGET}-$ARCH.tar.zst"
	echo "Extracting the $f..."
	tar xf $f && ls -lh $f && rm -f $f
}

pack_release() {
	local DEST="$PWD/release/release"
	local build_dir="src/out/${BLD_TARGET}_${ARCH}"
	mkdir -p "$DEST"
	case "$TARGET_OS" in
		android)
			local f suffix
			[[ $BLD_TARGET != cgms ]] || BLD_TARGET=cromite_gms
			[[ $BLD_TARGET = android ]] || suffix="_${BLD_TARGET}"
			find $build_dir/apks -name \*.aab -o -name \*.apk | xargs mv -vt "$DEST"
			cd "$DEST"
			for i in *; do
				f="${ARCH}_${i%.*}${suffix}.${i##*.}"
				mv $i "$f"
				[[ $f != *.apk ]] || xz -9 -vT0 "$f"
			done
			ls -la
			;;
		linux)
			find $build_dir -name \*.deb -o -name \*.rpm | xargs mv -vt "$DEST"
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
		if [[ $HOST_OS-$BLD_TARGET = linux-win ]]; then
			build/ciopfs -o use_ino third_party/depot_tools/win_toolchain/vs_files{.ciopfs,}
		fi
		echo "upload=yes" >> $GITHUB_OUTPUT
		gn ls "out/${BLD_TARGET}_${ARCH}" > ../targets-${BLD_TARGET}_${ARCH}.txt
		gn args "out/${BLD_TARGET}_${ARCH}"  --list > ../args-${BLD_TARGET}_${ARCH}.txt
		gn args "out/${BLD_TARGET}_${ARCH}"  --list --short | tee -a ../args-short-${BLD_TARGET}_${ARCH}.txt
		;;
esac
