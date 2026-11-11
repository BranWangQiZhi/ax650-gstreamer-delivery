#!/bin/bash
# Cross build GStreamer 1.22.12 + deps for AX650 (aarch64-none-linux-gnu, gcc 10.3)
# Usage: build.sh [clean|install]
set -e

CUR="$(cd "$(dirname "$0")" && pwd)"
SDK="$(cd "$CUR/../.." && pwd)"
STAGE="$CUR/stage"
SRC="$CUR/src"
TARBALLS="$CUR/tarballs"
CROSS=aarch64-none-linux-gnu-
TOOLCHAIN=/opt/toolchains/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin
NPROC=$(nproc)
HOST_TRIPLET=aarch64-none-linux-gnu

export PATH="$TOOLCHAIN:/root/.local/bin:$PATH"
export CC=${CROSS}gcc CXX=${CROSS}g++ CPP="${CROSS}gcc -E" AR=${CROSS}ar \
       STRIP=${CROSS}strip RANLIB=${CROSS}ranlib LD=${CROSS}ld \
       PKG_CONFIG_PATH="$STAGE/lib/pkgconfig:$STAGE/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$STAGE/lib/pkgconfig:$STAGE/share/pkgconfig"
export ACLOCAL_PATH=

MKDIR="mkdir -p"

# ---------- helpers ----------
if [ "$1" = "clean" ]; then
  rm -rf "$STAGE" "$SRC" "$CUR/out" "$CUR/gstreamer-aarch64-deploy.tar.gz"
  echo "gstreamer module cleaned"
  exit 0
fi

$MKDIR "$STAGE" "$SRC"

# generate meson cross file (absolute paths)
cat > "$CUR/aarch64-cross.txt" <<EOF
[binaries]
c = '${TOOLCHAIN}/${CROSS}gcc'
cpp = '${TOOLCHAIN}/${CROSS}g++'
ar = '${TOOLCHAIN}/${CROSS}ar'
strip = '${TOOLCHAIN}/${CROSS}strip'
nm = '${TOOLCHAIN}/${CROSS}nm'
ranlib = '${TOOLCHAIN}/${CROSS}ranlib'
ld = '${TOOLCHAIN}/${CROSS}ld'
pkg-config = '${CUR}/pkgcfg.sh'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
c_link_args = ['-L${STAGE}/lib', '-L${STAGE}/lib64', '-Wl,-rpath-link,${STAGE}/lib']
cpp_link_args = ['-L${STAGE}/lib', '-L${STAGE}/lib64', '-Wl,-rpath-link,${STAGE}/lib']
needs_exe_wrapper = true
EOF

# pkg-config wrapper for meson cross builds (only sees staging sysroot)
cat > "$CUR/pkgcfg.sh" <<EOF
#!/bin/sh
export PKG_CONFIG_PATH="${STAGE}/lib/pkgconfig:${STAGE}/share/pkgconfig"
export PKG_CONFIG_LIBDIR="${STAGE}/lib/pkgconfig:${STAGE}/share/pkgconfig"
exec pkg-config "\$@"
EOF
chmod +x "$CUR/pkgcfg.sh"

# native glib tools required by glib cross builds
if ! command -v glib-compile-resources >/dev/null 2>&1; then
  echo "installing native glib dev tools ..."
  apt-get install -y libglib2.0-dev-bin >/dev/null
fi

meson_build() { # $1=srcdir  $2=extra cmake-style opts "name=val" ...
  local name="$1" dir="$2"; shift 2
  local opts=""
  local optfile="$SRC/$dir/meson_options.txt"
  [ -f "$optfile" ] || optfile="$SRC/$dir/meson.options"
  for o in "$@"; do
    local key="${o%%=*}" val="${o#*=}" blk
    blk=$(grep -A2 -E "option[[:space:]]*\([[:space:]]*['\"]$key['\"]" "$optfile" 2>/dev/null | head -3)
    if [ -z "$blk" ]; then continue; fi
    if echo "$blk" | grep -qE "type[[:space:]]*:[[:space:]]*'boolean'"; then
      case "$val" in
        enabled|true) o="$key=true";;
        disabled|false) o="$key=false";;
      esac
    fi
    opts="$opts -D$o"
  done
  if [ ! -f "$SRC/$dir/meson.build" ]; then
    echo "=== $name has no meson.build, fallback to autotools"
    autotools_build "$dir" --disable-static
    return 0
  fi
  echo "=== meson build $name$opts"
  rm -rf "$SRC/$dir/build-gst"
  meson setup "$SRC/$dir/build-gst" "$SRC/$dir" \
    --cross-file "$CUR/aarch64-cross.txt" \
    --prefix="$STAGE" --libdir=lib --bindir=bin \
    --buildtype=release --default-library=shared \
    --wrap-mode=nofallback $opts
  ninja -C "$SRC/$dir/build-gst" -j "$NPROC"
  ninja -C "$SRC/$dir/build-gst" install
}

autotools_build() { # $1=dir, rest=extra configure args
  local dir="$1"; shift
  echo "=== autotools build $dir"
  cd "$SRC/$dir"
  [ -f Makefile ] && { make distclean >/dev/null 2>&1 || true; }
  ./configure --host=$HOST_TRIPLET --prefix="$STAGE" --libdir="$STAGE/lib" "$@"
  make -j "$NPROC"
  make install
  cd "$CUR"
}

untar() {
  local t="$TARBALLS/$1"
  local dest="$SRC"
  echo "=== extract $1"
  case "$1" in
    *.tar.xz) tar -xJf "$t" -C "$dest";;
    *.tar.gz) tar -xzf "$t" -C "$dest";;
    *.tar.bz2) tar -xjf "$t" -C "$dest";;
  esac
}

build_all() {
  # 1. zlib
  if [ ! -f "$STAGE/lib/libz.so" ]; then
    untar zlib-1.3.1.tar.gz
    (cd "$SRC/zlib-1.3.1" && CHOST=$HOST_TRIPLET ./configure --prefix="$STAGE" && make -j "$NPROC" && make install)
  fi
  # 2. libffi
  if [ ! -f "$STAGE/lib/libffi.so" ]; then
    untar libffi-3.4.4.tar.gz
    autotools_build libffi-3.4.4 --disable-static --disable-docs
  fi
  # 3. pcre2
  if [ ! -f "$STAGE/lib/libpcre2-8.so" ]; then
    untar pcre2-10.42.tar.bz2
    meson_build pcre2 pcre2-10.42 tests=disabled
  fi
  # 4. pcre1 (required by glib 2.72)
  if [ ! -f "$STAGE/lib/libpcre.so" ]; then
    untar pcre-8.45.tar.gz
    autotools_build pcre-8.45 --disable-static --disable-cpp --enable-utf8 --enable-unicode-properties
  fi
  # 5. glib
  if [ ! -f "$STAGE/lib/libglib-2.0.so" ]; then
    untar glib-2.72.4.tar.xz
    meson_build glib glib-2.72.4 introspection=disabled docs=false man=false \
      dtrace=disabled systemtap=disabled selinux=disabled libmount=disabled \
      tests=false installed_tests=false nls=disabled force_posix_threads=true
  fi
  # 6. libsrtp2
  if [ ! -f "$STAGE/lib/libsrtp2.so" ]; then
    untar libsrtp-2.5.0.tar.gz
    meson_build libsrtp libsrtp-2.5.0 tests=disabled
  fi
  # 7. json-glib
  if [ ! -f "$STAGE/lib/libjson-glib-1.0.so" ]; then
    untar json-glib-1.6.6.tar.xz
    meson_build json-glib json-glib-1.6.6 introspection=disabled docs=false tests=false man=false
  fi
  # 7. libunistring
  if [ ! -f "$STAGE/lib/libunistring.so" ]; then
    untar libunistring-1.1.tar.xz
    autotools_build libunistring-1.1 --disable-static
  fi
  # libunistring 1.1 不上报 .pc，手动补齐（libidn2/libpsl 依赖 pkg-config 探测）
  if [ ! -f "$STAGE/lib/pkgconfig/libunistring.pc" ]; then
    cat > "$STAGE/lib/pkgconfig/libunistring.pc" <<EOF
prefix=${STAGE}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libunistring
Description: GNU libunistring
Version: 1.1
Libs: -L\${libdir} -lunistring
Cflags: -I\${includedir}
EOF
  fi
  # 8. libidn2 (gendata/gentr46map 需在宿主执行，用 host gcc 生成码表)
  if [ ! -f "$STAGE/lib/libidn2.so" ]; then
    untar libidn2-2.3.7.tar.gz
    (
      cd "$SRC/libidn2-2.3.7"
      [ -f Makefile ] && { make distclean >/dev/null 2>&1 || true; }
      ./configure --host=$HOST_TRIPLET --prefix="$STAGE" --libdir="$STAGE/lib" \
        --disable-static --disable-doc
      cd lib
      gcc -I. -I.. -DIDN2_BUILDING -DSRCDIR=\".\" -I../gl -I../unistring gendata.c -o gendata
      gcc -I. -I.. -DIDN2_BUILDING -DSRCDIR=\".\" -I../gl -I../unistring gentr46map.c -o gentr46map
      ./gendata < ./Idna2008-15.0.0.txt > data.c
      ./gentr46map > tr46map_data.c
      touch data.c tr46map_data.c
      cd ..
      make -j "$NPROC" -C lib
      make -C lib install
    )
  fi
  # libidn2 未生成 .pc，手动补齐（libpsl 依赖）
  if [ ! -f "$STAGE/lib/pkgconfig/libidn2.pc" ]; then
    cat > "$STAGE/lib/pkgconfig/libidn2.pc" <<EOF
prefix=${STAGE}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libidn2
Description: GNU libidn2
Version: 2.3.7
Libs: -L\${libdir} -lidn2
Libs.private: -lunistring
Cflags: -I\${includedir}
EOF
  fi
  # 9. libpsl
  if [ ! -f "$STAGE/lib/libpsl.so" ]; then
    untar libpsl-0.21.5.tar.gz
    meson_build libpsl libpsl-0.21.5 docs=false tests=false man=false
  fi
  # 10/11. sqlite3 + libsoup3 仅 whipsink/whipsrc 需要（GStreamer 1.22 无这两个元素）。
  #        本项目用自研 apps/whip_push.c 完成 WHIP 信令（纯 socket，不依赖 libsoup），故跳过。
  #        若以后升级 GStreamer >= 1.24 想用官方 whipsink，再打开下面两段。
  # if [ ! -f "$STAGE/lib/libsqlite3.so" ]; then
  #   untar sqlite-autoconf-3460100.tar.gz
  #   autotools_build sqlite-autoconf-3460100 --disable-static --disable-readline
  # fi
  # if [ ! -f "$STAGE/lib/libsoup-3.0.so" ]; then
  #   untar libsoup-3.4.4.tar.xz
  #   meson_build libsoup libsoup-3.4.4 gssapi=disabled vapi=disabled gtk_doc=disabled \
  #     tests=disabled introspection=disabled sysprof=disabled tls_check=false
  # fi
  # 12. x264
  if [ ! -f "$STAGE/lib/libx264.so" ]; then
    untar x264-stable.tar.gz
    (cd "$SRC/x264-stable" && ./configure --host=$HOST_TRIPLET --prefix="$STAGE" \
      --enable-shared --disable-cli --enable-pic && make -j "$NPROC" && make install)
  fi
  # 13. gstreamer core
  if [ ! -f "$STAGE/lib/libgstreamer-1.0.so" ]; then
    untar gstreamer-1.22.12.tar.xz
    meson_build gstreamer gstreamer-1.22.12 tests=disabled examples=disabled \
      benchmarks=disabled gtk_doc=disabled introspection=disabled nls=disabled \
      libunwind=disabled libdw=disabled
  fi
  # 14. gst-plugins-base
  if [ ! -f "$STAGE/lib/libgstvideo-1.0.so" ]; then
    untar gst-plugins-base-1.22.12.tar.xz
    meson_build gst-plugins-base gst-plugins-base-1.22.12 tests=disabled examples=disabled \
      gtk_doc=disabled introspection=disabled nls=disabled orc=disabled gl=disabled \
      x11=disabled alsa=disabled
  fi
  # 15. gst-plugins-good (rtp/rtpmanager/udp ...)
  if [ ! -f "$STAGE/lib/gstreamer-1.0/libgstrtpmanager.so" ]; then
    untar gst-plugins-good-1.22.12.tar.xz
    meson_build gst-plugins-good gst-plugins-good-1.22.12 tests=disabled examples=disabled \
      gtk_doc=disabled nls=disabled orc=disabled glib_tools=disabled
  fi
  # 16. gst-plugins-ugly (x264enc)
  if [ ! -f "$STAGE/lib/gstreamer-1.0/libgstx264.so" ]; then
    untar gst-plugins-ugly-1.22.12.tar.xz
    meson_build gst-plugins-ugly gst-plugins-ugly-1.22.12 tests=disabled nls=disabled \
      gtk_doc=disabled x264=enabled gpl=enabled
  fi
  # 17. openssl from SDK third-party -> stage (libnice/dtls 需要)
  SDK_SSL="$SDK/third-party/openssl"
  if [ -d "$SDK_SSL/include/openssl" ] && [ ! -f "$STAGE/lib/pkgconfig/openssl.pc" ]; then
    echo "=== stage openssl from $SDK_SSL"
    cp -a "$SDK_SSL/include/openssl" "$STAGE/include/"
    cp -d "$SDK_SSL/lib/libcrypto.so"* "$SDK_SSL/lib/libssl.so"* "$STAGE/lib/" 2>/dev/null || true
    for n in libcrypto libssl; do
      libs="-l${n#lib}"
      cat > "$STAGE/lib/pkgconfig/$n.pc" <<EOF
prefix=${STAGE}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: $n
Description: OpenSSL from AX650 SDK
Version: 1.1.1a
Libs: -L\${libdir} $libs
Cflags: -I\${includedir}
EOF
    done
    cat > "$STAGE/lib/pkgconfig/openssl.pc" <<EOF
prefix=${STAGE}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: OpenSSL
Description: OpenSSL from AX650 SDK
Version: 1.1.1a
Requires: libssl libcrypto
Libs: -L\${libdir} -lssl -lcrypto
Cflags: -I\${includedir}
EOF
  fi
  # 18. libnice
  if [ ! -f "$STAGE/lib/libnice.so" ]; then
    untar libnice-0.1.21.tar.gz
    meson_build libnice libnice-0.1.21 gtk_doc=disabled tests=disabled \
      introspection=disabled
  fi
  # 19. gst-plugins-bad (webrtc/dtls/srtp)
  if [ ! -f "$STAGE/lib/gstreamer-1.0/libgstwebrtc.so" ]; then
    untar gst-plugins-bad-1.22.12.tar.xz
    meson_build gst-plugins-bad gst-plugins-bad-1.22.12 tests=disabled examples=disabled \
      gtk_doc=disabled introspection=disabled nls=disabled webrtc=enabled dtls=enabled \
      srtp=enabled
  fi
  # 20. whip_push: 自研 WHIP 信令客户端（webrtcbin + 极简 HTTP）
  if [ ! -f "$STAGE/bin/whip_push" ]; then
    echo "=== build whip_push"
    ${CROSS}gcc -O2 "${CUR}/apps/whip_push.c" -o "${STAGE}/bin/whip_push" \
      $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-webrtc-1.0 gstreamer-sdp-1.0 openssl) \
      -L"$STAGE/lib" -Wl,-rpath-link,"$STAGE/lib"
    ${CROSS}strip "${STAGE}/bin/whip_push" 2>/dev/null || true
  fi
  # 21. glibc 2.30 兼容层（板子 glibc 2.30 vs 工具链 sysroot 2.33）
  if [ ! -f "$STAGE/lib/libglibc230_compat.so" ]; then
    echo "=== build glibc230_compat"
    ${CROSS}gcc -shared -fPIC -O2 "${CUR}/apps/glibc230_compat.c" \
      -o "$STAGE/lib/libglibc230_compat.so" \
      -Wl,--version-script="${CUR}/apps/glibc230_compat.map" -nostartfiles
  fi
  echo "GST_BUILD_ALL_DONE"
}

install_rootfs() {
  local ROOTFS="$SDK/rootfs/rootfs/usr/local"
  $MKDIR "$ROOTFS/lib/gstreamer-1.0" "$ROOTFS/bin" "$ROOTFS/libexec/gstreamer-1.0"
  # 统一做一次 glibc 版本降级（幂等）
  python3 "${CUR}/apps/patch_glibc_ver.py" "$STAGE/lib" "$STAGE/bin" >/dev/null || true
  # binaries
  for b in "$STAGE"/bin/*; do
    [ -f "$b" ] && cp -d "$b" "$ROOTFS/bin/"
  done
  # libs
  cp -d "$STAGE"/lib/*.so* "$ROOTFS/lib/" 2>/dev/null || true
  # plugins
  cp -d "$STAGE"/lib/gstreamer-1.0/*.so* "$ROOTFS/lib/gstreamer-1.0/"
  # libexec (gst-plugin-scanner 必需)
  cp -d "$STAGE"/libexec/gstreamer-1.0/* "$ROOTFS/libexec/gstreamer-1.0/" 2>/dev/null || true
  # strip plugins/lib for size
  ${CROSS}strip --strip-unneeded "$ROOTFS"/lib/gstreamer-1.0/*.so 2>/dev/null || true
  # board 业务脚本(交付仓库镜像才有 ../board; SDK third-party 内镜像无此目录则跳过)
  BOARD_DIR="$CUR/../board"
  if [ -d "$BOARD_DIR" ]; then
    for s in flex_start.sh flex_srs.sh rtp_bridge.sh; do
      cp "$BOARD_DIR/$s" "$STAGE/bin/$s"
    done
    echo "Board scripts packed into stage/bin: flex_start.sh flex_srs.sh rtp_bridge.sh"
  else
    echo "WARN: $BOARD_DIR 不存在, 部署包不含业务脚本(仅运行时)"
  fi
  # deploy tarball for the board
  tar -czf "$CUR/gstreamer-aarch64-deploy.tar.gz" -C "$STAGE" bin lib libexec
  echo "Install gstreamer to SDK rootfs success: $ROOTFS"
  echo "Deploy tarball: $CUR/gstreamer-aarch64-deploy.tar.gz"
}

case "$1" in
  install) install_rootfs ;;
  *) build_all ;;
esac
