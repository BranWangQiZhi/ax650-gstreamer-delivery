#!/bin/bash
# GStreamer module source downloader for AX650 SDK
set -e
DIR="$(cd "$(dirname "$0")" && pwd)/tarballs"
mkdir -p "$DIR"
cd "$DIR"
dl() {
  [ -s "$2" ] && { echo "skip $2"; return; }
  echo "downloading $2 ..."
  curl -fL --retry 3 -o "$2" "$1"
}
# --- core deps ---
dl https://sourceforge.net/projects/pcre/files/pcre/8.45/pcre-8.45.tar.gz/download pcre-8.45.tar.gz
dl https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.bz2 pcre2-10.42.tar.bz2
dl https://github.com/libffi/libffi/releases/download/v3.4.4/libffi-3.4.4.tar.gz libffi-3.4.4.tar.gz
dl https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz zlib-1.3.1.tar.gz
dl https://download.gnome.org/sources/glib/2.72/glib-2.72.4.tar.xz glib-2.72.4.tar.xz
dl https://github.com/cisco/libsrtp/archive/refs/tags/v2.5.0.tar.gz libsrtp-2.5.0.tar.gz
dl https://code.videolan.org/videolan/x264/-/archive/stable/x264-stable.tar.gz x264-stable.tar.gz
# --- webrtc deps (json-glib, libsoup3 chain) ---
dl https://download.gnome.org/sources/json-glib/1.6/json-glib-1.6.6.tar.xz json-glib-1.6.6.tar.xz
dl https://ftp.gnu.org/gnu/libunistring/libunistring-1.1.tar.xz libunistring-1.1.tar.xz
dl https://ftp.gnu.org/gnu/libidn/libidn2-2.3.7.tar.gz libidn2-2.3.7.tar.gz
dl https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz libpsl-0.21.5.tar.gz
dl https://www.sqlite.org/2024/sqlite-autoconf-3460100.tar.gz sqlite-autoconf-3460100.tar.gz
dl https://download.gnome.org/sources/libsoup/3.4/libsoup-3.4.4.tar.xz libsoup-3.4.4.tar.xz
# --- libnice ---
dl https://github.com/libnice/libnice/archive/refs/tags/0.1.21.tar.gz libnice-0.1.21.tar.gz
# --- gstreamer ---
dl https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.22.12.tar.xz gstreamer-1.22.12.tar.xz
dl https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-1.22.12.tar.xz gst-plugins-base-1.22.12.tar.xz
dl https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.22.12.tar.xz gst-plugins-good-1.22.12.tar.xz
dl https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-1.22.12.tar.xz gst-plugins-bad-1.22.12.tar.xz
dl https://gstreamer.freedesktop.org/src/gst-plugins-ugly/gst-plugins-ugly-1.22.12.tar.xz gst-plugins-ugly-1.22.12.tar.xz
echo "ALL DOWNLOADS DONE"
ls -la
