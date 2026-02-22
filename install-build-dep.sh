#!/bin/bash -e

# Copyright 2012 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to install everything needed to build chromium (well, ideally, anyway)
# including items requiring sudo privileges.
# See https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md
# and https://chromium.googlesource.com/chromium/src/+/HEAD/docs/android_build_instructions.md
# https://chromium.googlesource.com/chromium/src/+/refs/tags/112.0.5615.172/build/install-build-deps.sh

usage() {
  echo "Usage: $0 [--options]"
  echo "Options:"
  echo -e "\t--syms: enable installation of debugging symbols"
  echo -e "\t--lib32: enable installation of 32-bit libraries, e.g. for V8 snapshot"
  echo -e "\t--android: enable installation of android dependencies"
  echo -e "\t--arm: enable installation of arm cross toolchain"
  echo -e "\t--chromeos-fonts: enable or disable installation of Chrome OS fonts"
  echo -e "\t--nacl: enable installation of prerequisites for building"\
       "standalone NaCl and all its toolchains"
  echo -e "\t--no-prompt: silently select standard options/defaults"
  echo -e "\t--quick-check: quickly try to determine if dependencies are installed"
  echo -e "\t               (this avoids interactive prompts and sudo commands,"
  echo -e "\t               so might not be 100% accurate)"
  echo -e "\t--unsupported: attempt installation even on unsupported systems"
  echo -e "\t               Script will prompt interactively if options not given."
  exit 1
}

# Build list of apt packages in dpkg --get-selections format.
build_apt_package_list() {
  echo "Building apt package list." >&2
  apt-cache dumpavail | \
    python3 -c 'import re,sys; \
o = sys.stdin.read(); \
p = {"i386": ":i386"}; \
f = re.M | re.S; \
r = re.compile(r"^Package: (.+?)$.+?^Architecture: (.+?)$", f); \
m = ["%s%s" % (x, p.get(y, "")) for x, y in re.findall(r, o)]; \
print("\n".join(m))'
}

# Checks whether a particular package is available in the repos.
# Uses pre-formatted ${apt_package_list}.
# USAGE: $ package_exists <package name>
package_exists() {
  if [ -z "${apt_package_list}" ]; then
    echo "Call build_apt_package_list() prior to calling package_exists()" >&2
    apt_package_list=$(build_apt_package_list)
  fi
  # `grep` takes a regex string, so the +'s in package names, e.g. "libstdc++",
  # need to be escaped.
  local escaped="$(echo $1 | sed 's/[\~\+\.\:-]/\\&/g')"
  [ ! -z "$(grep "^${escaped}$" <<< "${apt_package_list}")" ]
}

do_inst_arm=0
do_inst_nacl=0
do_inst_android=0
do_inst_syms=0

while [ "$1" != "" ]
do
  case "$1" in
  --syms)                    do_inst_syms=1;;
  --lib32)                   do_inst_lib32=1;;
  --android)                 do_inst_android=1;;
  --arm)                     do_inst_arm=1;;
  --chromeos-fonts)          do_inst_chromeos_fonts=1;;
  --nacl)                    do_inst_nacl=1;;
  --no-prompt)               do_default=1
                             do_quietly="-qq --assume-yes"
    ;;
  --quick-check)             do_quick_check=1;;
  --unsupported)             do_unsupported=1;;
  *) usage;;
  esac
  shift
done

if [ "$do_inst_arm" = "1" ]; then
  do_inst_lib32=1
fi

if [ "$do_inst_android" = "1" ]; then
  do_inst_lib32=1
fi

# Check for lsb_release command in $PATH
if ! which lsb_release > /dev/null; then
  echo "ERROR: lsb_release not found in \$PATH" >&2
  echo "try: sudo apt-get install lsb-release" >&2
  exit 1;
fi

distro_codename=$(lsb_release --codename --short)
distro_id=$(lsb_release --id --short)
supported_codenames="(bionic|focal|jammy|noble)"
supported_ids="(Debian)"
if [ 0 -eq "${do_unsupported-0}" ] && [ 0 -eq "${do_quick_check-0}" ] ; then
  if [[ ! $distro_codename =~ $supported_codenames &&
        ! $distro_id =~ $supported_ids ]]; then
    echo -e "ERROR: The only supported distros are:\n" \
      "\tUbuntu 18.04 LTS (bionic with EoL April 2028)\n" \
      "\tUbuntu 20.04 LTS (focal with EoL April 2030)\n" \
      "\tUbuntu 22.04 LTS (jammy with EoS June 2027)\n" \
      "\tUbuntu 24.04 LTS (noble with EoS June 2029)\n" \
      "\tDebian 10 (buster) or later"  >&2
      # EoS refers to end of standard support and does not include extended security support.
    exit 1
  fi

# Check system architecture
  if ! uname -m | egrep -q "i686|x86_64|aarch64"; then
    echo "Only x86 and ARM64 architectures are currently supported" >&2
    exit 1
  fi
fi

if [ "x$(id -u)" != x0 ] && [ 0 -eq "${do_quick_check-0}" ]; then
  echo "Running as non-root user."
  echo "You might have to enter your password one or more times for 'sudo'."
  echo
fi

if [ 0 -eq "${do_quick_check-0}" ] ; then
  if [ "$do_inst_lib32" = "1" ] || [ "$do_inst_nacl" = "1" ]; then
    sudo dpkg --add-architecture i386
  fi
  if ! grep -q 'deb\s\+http' /etc/apt/sources.list && [ "$distro_id" = "Ubuntu" ]; then
    apt_sources_list="main restricted universe multiverse"
    mirror="http://azure.archive.ubuntu.com/ubuntu"
    cat > sources.list <<-EOF
      deb $mirror $distro_codename $apt_sources_list
      deb $mirror ${distro_codename}-updates $apt_sources_list
      deb $mirror ${distro_codename}-backports $apt_sources_list
      deb $mirror ${distro_codename}-security $apt_sources_list
EOF
    sudo mv sources.list /etc/apt/
  fi
  sudo apt-get update
fi

# Populate ${apt_package_list} for package_exists() parsing.
apt_package_list=$(build_apt_package_list)

# Packages needed for chromeos only
chromeos_dev_list="libbluetooth-dev libxkbcommon-dev mesa-common-dev zstd"

if package_exists realpath; then
  chromeos_dev_list="${chromeos_dev_list} realpath"
fi

# Packages needed for development
dev_list="\
  binutils
  bison
  bzip2
  cdbs
  curl
  dbus-x11
  dpkg-dev
  elfutils
  devscripts
  fakeroot
  flex
  git-core
  gperf
  libasound2-dev
  libatspi2.0-dev
  libbrlapi-dev
  libbz2-dev
  libcairo2-dev
  libcap-dev
  libc6-dev
  libcups2-dev
  libcurl4-gnutls-dev
  libdrm-dev
  libelf-dev
  libevdev-dev
  libffi-dev
  libfuse2
  libgbm-dev
  libglib2.0-dev
  libglu1-mesa-dev
  libgtk-3-dev
  libkrb5-dev
  libnspr4-dev
  libnss3-dev
  libpam0g-dev
  libpci-dev
  libpulse-dev
  libsctp-dev
  libspeechd-dev
  libsqlite3-dev
  libssl-dev
  libsystemd-dev
  libudev-dev
  libva-dev
  libwww-perl
  libxshmfence-dev
  libxslt1-dev
  libxss-dev
  libxt-dev
  libxtst-dev
  lighttpd
  locales
  openbox
  p7zip
  patch
  perl
  pkg-config
  rpm
  ruby
  uuid-dev
  wdiff
  x11-utils
  xcompmgr
  xz-utils
  zip
  $chromeos_dev_list
"

# 64-bit systems need a minimum set of 32-bit compat packages for the pre-built
# NaCl binaries.
if file -L /sbin/init | grep -q 'ELF 64-bit'; then
  dev_list="${dev_list} libc6-i386 lib32stdc++6"

  # lib32gcc-s1 used to be called lib32gcc1 in older distros.
  if package_exists lib32gcc-s1; then
    dev_list="${dev_list} lib32gcc-s1"
  elif package_exists lib32gcc1; then
    dev_list="${dev_list} lib32gcc1"
  fi
fi

# Run-time libraries required by chromeos only
chromeos_lib_list="libpulse0 libbz2-1.0"

# List of required run-time libraries
common_lib_list="\
  lib32z1
  libatk1.0-0
  libatspi2.0-0
  libc6
  libcairo2
  libcap2
  libcgi-session-perl
  libcups2
  libdrm2
  libegl1
  libevdev2
  libexpat1
  libfontconfig1
  libfreetype6
  libgbm1
  libglib2.0-0
  libgl1
  libgtk-3-0
  libpam0g
  libpango-1.0-0
  libpangocairo-1.0-0
  libpci3
  libpcre3
  libpixman-1-0
  libspeechd2
  libstdc++6
  libsqlite3-0
  libuuid1
  libwayland-egl1
  libwayland-egl1-mesa
  libx11-6
  libx11-xcb1
  libxau6
  libxcb1
  libxcomposite1
  libxcursor1
  libxdamage1
  libxdmcp6
  libxext6
  libxfixes3
  libxi6
  libxinerama1
  libxrandr2
  libxrender1
  libxtst6
  x11-utils
  x11-xserver-utils
  xserver-xorg-core
  xserver-xorg-video-dummy
  xvfb
  zlib1g
"

if package_exists libffi8; then
  common_lib_list="${common_lib_list} libffi8"
elif package_exists libffi7; then
  common_lib_list="${common_lib_list} libffi7"
elif package_exists libffi6; then
  common_lib_list="${common_lib_list} libffi6"
fi

if package_exists libncurses6; then
  common_lib_list+=" libncurses6"
else
  common_lib_list+=" libncurses5"
fi

if package_exists libasound2t64; then
  common_lib_list="${common_lib_list} libasound2t64"
else
  common_lib_list+=" libasound2"
fi

# Full list of required run-time libraries
lib_list="\
  $common_lib_list
  $chromeos_lib_list
"

# 32-bit libraries needed e.g. to compile V8 snapshot for Android or armhf
lib32_list="linux-libc-dev:i386 libpci3:i386"

# 32-bit libraries needed for a 32-bit build
# includes some 32-bit libraries required by the Android SDK
# See https://developer.android.com/sdk/installing/index.html?pkg=tools
lib32_list="$lib32_list
  libasound2:i386
  libatk-bridge2.0-0:i386
  libatk1.0-0:i386
  libatspi2.0-0:i386
  libdbus-1-3:i386
  libegl1:i386
  libgl1:i386
  libglib2.0-0:i386
  libnss3:i386
  libpango-1.0-0:i386
  libpangocairo-1.0-0:i386
  libstdc++6:i386
  libwayland-egl1:i386
  libx11-xcb1:i386
  libxcomposite1:i386
  libxdamage1:i386
  libxkbcommon0:i386
  libxrandr2:i386
  libxtst6:i386
  zlib1g:i386
  linux-libc-dev:i386
  libexpat1:i386
  libpci3:i386
"

if package_exists "libncurses6:i386"; then
  lib32_list+=" libncurses6:i386"
else
  lib32_list+=" libncurses5:i386"
fi

# arm cross toolchain packages needed to build chrome on armhf
arm_list="libc6-dev-armhf-cross
          linux-libc-dev-armhf-cross
          g++-arm-linux-gnueabihf"

# Work around for dependency issue Ubuntu: http://crbug.com/435056
case $distro_codename in
  bionic)
    arm_list+=" g++-5-multilib-arm-linux-gnueabihf
                gcc-5-multilib-arm-linux-gnueabihf
                gcc-arm-linux-gnueabihf"
    ;;
  focal)
    arm_list+=" g++-10-multilib-arm-linux-gnueabihf
                gcc-10-multilib-arm-linux-gnueabihf
                gcc-arm-linux-gnueabihf"
    ;;
  jammy)
    arm_list+=" gcc-arm-linux-gnueabihf
                g++-11-arm-linux-gnueabihf
                gcc-11-arm-linux-gnueabihf"
    ;;
  noble)
    arm_list+=" gcc-arm-linux-gnueabihf
                g++-13-arm-linux-gnueabihf
                gcc-13-arm-linux-gnueabihf"
    ;;
esac

# Packages to build NaCl, its toolchains, and its ports.
naclports_list="ant autoconf bison cmake gawk intltool xutils-dev xsltproc"
nacl_list="\
  g++-mingw-w64-i686
  lib32z1-dev
  libasound2:i386
  libcap2:i386
  libelf-dev:i386
  libfontconfig1:i386
  libglib2.0-0:i386
  libgpm2:i386
  libncurses5:i386
  libnss3:i386
  libpango-1.0-0:i386
  libssl-dev:i386
  libtinfo-dev
  libtinfo-dev:i386
  libtool
  libudev1:i386
  libuuid1:i386
  libxcomposite1:i386
  libxcursor1:i386
  libxdamage1:i386
  libxi6:i386
  libxrandr2:i386
  libxss1:i386
  libxtst6:i386
  texinfo
  xvfb
  ${naclports_list}
"

# Some package names have changed over time
if package_exists libssl-dev; then
  nacl_list="${nacl_list} libssl-dev:i386"
elif package_exists libssl1.1; then
  nacl_list="${nacl_list} libssl1.1:i386"
elif package_exists libssl1.0.2; then
  nacl_list="${nacl_list} libssl1.0.2:i386"
else
  nacl_list="${nacl_list} libssl1.0.0:i386"
fi
if package_exists libtinfo5; then
  nacl_list="${nacl_list} libtinfo5"
fi
if package_exists libpng16-16t64; then
  lib_list="${lib_list} libpng16-16t64"
elif package_exists libpng16-16; then
  lib_list="${lib_list} libpng16-16"
else
  lib_list="${lib_list} libpng12-0"
fi
if package_exists libnspr4; then
  lib_list="${lib_list} libnspr4 libnss3"
else
  lib_list="${lib_list} libnspr4-0d libnss3-1d"
fi
if package_exists libjpeg-dev; then
  dev_list="${dev_list} libjpeg-dev"
else
  dev_list="${dev_list} libjpeg62-dev"
fi
if package_exists libudev1; then
  dev_list="${dev_list} libudev1"
  nacl_list="${nacl_list} libudev1:i386"
else
  dev_list="${dev_list} libudev0"
  nacl_list="${nacl_list} libudev0:i386"
fi
if package_exists libbrlapi0.8; then
  dev_list="${dev_list} libbrlapi0.8"
elif package_exists libbrlapi0.7; then
  dev_list="${dev_list} libbrlapi0.7"
elif package_exists libbrlapi0.6; then
  dev_list="${dev_list} libbrlapi0.6"
else
  dev_list="${dev_list} libbrlapi0.5"
fi
if package_exists libav-tools; then
  dev_list="${dev_list} libav-tools"
fi

if package_exists lib32ncurses5-dev; then
  nacl_list="${nacl_list} lib32ncurses5-dev"
else
  nacl_list="${nacl_list} lib32ncurses-dev"
fi

# Some packages are only needed if the distribution actually supports
# installing them.
if package_exists appmenu-gtk; then
  lib_list="$lib_list appmenu-gtk"
fi
if package_exists libgnome-keyring0; then
  lib_list="${lib_list} libgnome-keyring0"
fi
if package_exists libgnome-keyring-dev; then
  lib_list="${lib_list} libgnome-keyring-dev"
fi
if package_exists libvulkan-dev; then
  dev_list="${dev_list} libvulkan-dev"
fi
if package_exists libvulkan1; then
  lib_list="${lib_list} libvulkan1"
fi
if package_exists libinput10; then
  lib_list="${lib_list} libinput10"
fi
if package_exists libinput-dev; then
    dev_list="${dev_list} libinput-dev"
fi
if package_exists snapcraft; then
    dev_list="${dev_list} snapcraft"
fi

# Cross-toolchain strip is needed for building the sysroots.
if package_exists binutils-arm-linux-gnueabihf; then
  dev_list="${dev_list} binutils-arm-linux-gnueabihf"
fi
if package_exists binutils-aarch64-linux-gnu; then
  dev_list="${dev_list} binutils-aarch64-linux-gnu"
fi
if package_exists binutils-mipsel-linux-gnu; then
  dev_list="${dev_list} binutils-mipsel-linux-gnu"
fi
if package_exists binutils-mips64el-linux-gnuabi64; then
  dev_list="${dev_list} binutils-mips64el-linux-gnuabi64"
fi

# When cross building for arm/Android on 64-bit systems the host binaries
# that are part of v8 need to be compiled with -m32 which means
# that basic multilib support is needed.
if file -L /sbin/init | grep -q 'ELF 64-bit'; then
  # gcc-multilib conflicts with the arm cross compiler but
  # g++-X.Y-multilib gives us the 32-bit support that we need. Find out the
  # appropriate value of X and Y by seeing what version the current
  # distribution's g++-multilib package depends on.
  multilib_package=$(apt-cache depends g++-multilib --important | \
      grep -E --color=never --only-matching '\bg\+\+-[0-9.]+-multilib\b')
  lib32_list="$lib32_list $multilib_package"
fi

if [ "$do_inst_syms" = "1" ]; then
  echo "Including debugging symbols."

  # Debian is in the process of transitioning to automatic debug packages, which
  # have the -dbgsym suffix (https://wiki.debian.org/AutomaticDebugPackages).
  # Untransitioned packages have the -dbg suffix.  And on some systems, neither
  # will be available, so exclude the ones that are missing.
  dbg_package_name() {
    if package_exists "$1-dbgsym"; then
      echo "$1-dbgsym"
    elif package_exists "$1-dbg"; then
      echo "$1-dbg"
    fi
  }

  for package in "${common_lib_list}"; do
    dbg_list="$dbg_list $(dbg_package_name ${package})"
  done

  # Debugging symbols packages not following common naming scheme
  if [ "$(dbg_package_name libstdc++6)" == "" ]; then
    if package_exists libstdc++6-8-dbg; then
      dbg_list="${dbg_list} libstdc++6-8-dbg"
    elif package_exists libstdc++6-7-dbg; then
      dbg_list="${dbg_list} libstdc++6-7-dbg"
    elif package_exists libstdc++6-6-dbg; then
      dbg_list="${dbg_list} libstdc++6-6-dbg"
    elif package_exists libstdc++6-5-dbg; then
      dbg_list="${dbg_list} libstdc++6-5-dbg"
    elif package_exists libstdc++6-4.9-dbg; then
      dbg_list="${dbg_list} libstdc++6-4.9-dbg"
    elif package_exists libstdc++6-4.8-dbg; then
      dbg_list="${dbg_list} libstdc++6-4.8-dbg"
    elif package_exists libstdc++6-4.7-dbg; then
      dbg_list="${dbg_list} libstdc++6-4.7-dbg"
    elif package_exists libstdc++6-4.6-dbg; then
      dbg_list="${dbg_list} libstdc++6-4.6-dbg"
    fi
  fi
  if [ "$(dbg_package_name libatk1.0-0)" == "" ]; then
    dbg_list="$dbg_list $(dbg_package_name libatk1.0)"
  fi
  if [ "$(dbg_package_name libpango-1.0-0)" == "" ]; then
    dbg_list="$dbg_list $(dbg_package_name libpango1.0-dev)"
  fi
else
  echo "Skipping debugging symbols."
  dbg_list=
fi

if [ "$do_inst_lib32" = "1" ]; then
  echo "Including 32-bit libraries."
else
  echo "Skipping 32-bit libraries."
  lib32_list=
fi

if [ "$do_inst_android" = "1" ]; then
  echo "Including Android dependencies."
else
  echo "Skipping Android dependencies."
fi

if [ "$do_inst_arm" = "1" ]; then
  echo "Including ARM cross toolchain."
else
  echo "Skipping ARM cross toolchain."
  arm_list=
fi

if [ "$do_inst_nacl" = "1" ]; then
  echo "Including NaCl, NaCl toolchain, NaCl ports dependencies."
else
  echo "Skipping NaCl, NaCl toolchain, NaCl ports dependencies."
  nacl_list=
fi

# The `sort -r -s -t: -k2` sorts all the :i386 packages to the front, to avoid
# confusing dpkg-query (crbug.com/446172).
packages="$(
  echo "${dev_list} ${lib_list} ${dbg_list} ${lib32_list} ${arm_list}" \
       "${nacl_list}" | tr " " "\n" | \
       sort -u | sort -r -s -t: -k2 | tr "\n" " "
)"

if [ 1 -eq "${do_quick_check-0}" ] ; then
  if ! missing_packages="$(dpkg-query -W -f ' ' ${packages} 2>&1)"; then
    # Distinguish between packages that actually aren't available to the
    # system (i.e. not in any repo) and packages that just aren't known to
    # dpkg (i.e. managed by apt).
    missing_packages="$(echo "${missing_packages}" | awk '{print $NF}')"
    not_installed=""
    unknown=""
    for p in ${missing_packages}; do
      if apt-cache show ${p} > /dev/null 2>&1; then
        not_installed="${p}\n${not_installed}"
      else
        unknown="${p}\n${unknown}"
      fi
    done
    if [ -n "${not_installed}" ]; then
      echo "WARNING: The following packages are not installed:"
      echo -e "${not_installed}" | sed -e "s/^/  /"
    fi
    if [ -n "${unknown}" ]; then
      echo "WARNING: The following packages are unknown to your system"
      echo "(maybe missing a repo or need to 'sudo apt-get update'):"
      echo -e "${unknown}" | sed -e "s/^/  /"
    fi
    exit 1
  fi
  exit 0
fi

echo "Finding missing packages..."
# Intentionally leaving $packages unquoted so it's more readable.
echo "Packages required: " $packages
echo
query_cmd="apt-get --just-print install $(echo $packages)"
if cmd_output="$(LANGUAGE=en LANG=C $query_cmd)"; then
  new_list=$(echo "$cmd_output" |
    sed -e '1,/The following NEW packages will be installed:/d;s/^  //;t;d' |
    sed 's/ *$//')
  upgrade_list=$(echo "$cmd_output" |
    sed -e '1,/The following packages will be upgraded:/d;s/^  //;t;d' |
    sed 's/ *$//')
  if [ -z "$new_list" ] && [ -z "$upgrade_list" ]; then
    echo "No missing packages, and the packages are up to date."
  else
    echo "Installing and upgrading packages: $new_list $upgrade_list."
    sudo apt-get install ${do_quietly-} ${new_list} ${upgrade_list}
  fi
  echo
else
  # An apt-get exit status of 100 indicates that a real error has occurred.

  # I am intentionally leaving out the '"'s around query_cmd,
  # as this makes it easier to cut and paste the output
  echo "The following command failed: " ${query_cmd}
  echo
  echo "It produced the following output:"
  echo "$cmd_output"
  echo
  echo "You will have to install the above packages yourself."
  echo
  exit 100
fi

# Install the Chrome OS default fonts. This must go after running
# apt-get, since install-chromeos-fonts depends on curl.
if [ "$do_inst_chromeos_fonts" = "1" ]; then
  echo
  echo "Installing Chrome OS fonts."
  dir=`echo $0 | sed -r -e 's/\/[^/]+$//'`
  if ! sudo $dir/linux/install-chromeos-fonts.py; then
    echo "ERROR: The installation of the Chrome OS default fonts failed."
    if [ `stat -f -c %T $dir` == "nfs" ]; then
      echo "The reason is that your repo is installed on a remote file system."
    else
      echo "This is expected if your repo is installed on a remote file system."
    fi
    echo "It is recommended to install your repo on a local file system."
    echo "You can skip the installation of the Chrome OS default fonts with"
    echo "the command line option: --no-chromeos-fonts."
    exit 1
  fi
else
  echo "Skipping installation of Chrome OS fonts."
fi

echo "Installing locales."
CHROMIUM_LOCALES="da_DK.UTF-8 fr_FR.UTF-8 he_IL.UTF-8 zh_TW.UTF-8"
LOCALE_GEN=/etc/locale.gen
if [ -e ${LOCALE_GEN} ]; then
  OLD_LOCALE_GEN="$(cat /etc/locale.gen)"
  for CHROMIUM_LOCALE in ${CHROMIUM_LOCALES}; do
    sudo sed -i "s/^# ${CHROMIUM_LOCALE}/${CHROMIUM_LOCALE}/" ${LOCALE_GEN}
  done
  # Regenerating locales can take a while, so only do it if we need to.
  if (echo "${OLD_LOCALE_GEN}" | cmp -s ${LOCALE_GEN}); then
    echo "Locales already up-to-date."
  else
    sudo locale-gen
  fi
else
  for CHROMIUM_LOCALE in ${CHROMIUM_LOCALES}; do
    sudo locale-gen ${CHROMIUM_LOCALE}
  done
fi
