#!/usr/bin/env bash
# Builds FFmpeg (+ LAME for MP3, libopus for Opus, mbedTLS for HTTPS) for iOS device
# and simulator, and packages them as three xcframeworks in Frameworks/:
#   FFmpegCore   - libavcodec/format/filter/... + lame + mbedtls in one dylib (LGPL, dynamically linked)
#   FFmpegTool   - the `ffmpeg` command-line tool, built as a library (entry point: main)
#   FFprobeTool  - the `ffprobe` command-line tool, built as a library
# The app calls each tool's `main` in-process (iOS cannot spawn processes).
# Also builds plain macOS `ffmpeg`/`ffprobe` executables with the identical
# configuration into build/deps/macos/bin, so Engine/tests run against the same
# codecs and formats the phone has.
#
# Only the components yt-dlp actually uses are compiled in (see COMPONENTS below).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
BUILD="$ROOT/build/deps"
OUT="$ROOT/Frameworks"
FFMPEG_VER=9.0.2
LAME_VER=3.100
MBEDTLS_VER=3.6.7
OPUS_VER=1.6.1
MIN_IOS=17.0
JOBS=$(sysctl -n hw.ncpu)

# Every source is pinned by SHA-256. FFmpeg's hash was taken after checking its
# release signature (ffmpeg.org/ffmpeg-devel.asc); mbedTLS's matches its GitHub
# release digest; LAME 3.100's is the long-published one (same as Homebrew's);
# libopus's matches xiph.org's SHA256SUMS.txt and Homebrew's formula.
fetch() { # url dest-dir sha256
  local url=$1 dir=$2 sha=$3
  [ -d "$VENDOR/$dir" ] && return
  mkdir -p "$VENDOR"; echo "Fetching $url"
  local f="$VENDOR/$(basename "$url")"
  curl -fsSL -o "$f" "$url"
  echo "$sha  $f" | shasum -a 256 -c - >/dev/null || { echo "CHECKSUM MISMATCH for $url"; rm -f "$f"; exit 1; }
  tar xf "$f" -C "$VENDOR"
}
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz" "ffmpeg-$FFMPEG_VER" \
  8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VER/lame-$LAME_VER.tar.gz" "lame-$LAME_VER" \
  ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
fetch "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VER/mbedtls-$MBEDTLS_VER.tar.bz2" "mbedtls-$MBEDTLS_VER" \
  a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VER.tar.gz" "opus-$OPUS_VER" \
  6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1

# In-process patches (marker ALEMBIC_PATCHED_V2; re-extract the tarball to re-apply):
#  - ffprobe calls exit(1) on a few failures; in-process that would kill the app.
#  - ffmpeg must not install process-wide SIGINT/SIGTERM handlers (its handler calls
#    exit(123) after four signals) when running inside the app.
#  - alembic_ffmpeg_request_stop(): the host app's cancel. It sets the signal count
#    to 2 so the I/O interrupt callback fires even after transcoding has started, so a
#    stalled network read is abandoned at once (cancelled output is discarded anyway).
FFSRC="$VENDOR/ffmpeg-$FFMPEG_VER"
if ! grep -q ALEMBIC_PATCHED_V2 "$FFSRC/fftools/ffmpeg.c"; then
  if grep -q ALEMBIC_PATCHED "$FFSRC/fftools/ffmpeg.c"; then
    rm -rf "$FFSRC"; tar xf "$VENDOR/ffmpeg-$FFMPEG_VER.tar.xz" -C "$VENDOR" || exit 1
  fi
  sed -i '' 's/exit(1);/return AVERROR_EXIT; \/\* ALEMBIC_PATCHED \*\//' "$FFSRC/fftools/ffprobe.c"
  /usr/bin/python3 - "$FFSRC/fftools/ffmpeg.c" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
a = "    SIGNAL(SIGINT , sigterm_handler); /* Interrupt (ANSI).    */"
assert s.count(a) == 1
s = s.replace(a, "#ifndef ALEMBIC_IN_PROCESS /* ALEMBIC_PATCHED_V2 */\n" + a)
b = "#ifdef SIGXCPU\n    SIGNAL(SIGXCPU, sigterm_handler);\n#endif\n"
assert s.count(b) == 1
s = s.replace(b, b + "#endif /* ALEMBIC_IN_PROCESS */\n")
s += """
/* ALEMBIC_PATCHED_V2: in-process stop request from the host app */
void alembic_ffmpeg_request_stop(void);
void alembic_ffmpeg_request_stop(void)
{
    received_sigterm = SIGINT;
    received_nb_signals = 2;
}
"""
open(p, "w").write(s)
PYEOF
fi

# Everything yt-dlp's downloaders and postprocessors use (yt_dlp/postprocessor/ffmpeg.py,
# embedthumbnail.py, downloader/external.py), plus what ffprobe needs to identify streams.
COMPONENTS=(
  --disable-everything
  --enable-protocol=file,pipe,http,https,tls,tcp,crypto,data,concat,concatf,httpproxy
  --enable-demuxer=mov,matroska,webm_dash_manifest,mp3,aac,ac3,eac3,flac,ogg,wav,w64,aiff,hls,dash,mpegts,flv,concat,ffmetadata,image2,image_jpeg_pipe,image_png_pipe,image_webp_pipe,image_gif_pipe,gif,mjpeg,h264,hevc,ivf,obu,webvtt,srt,ass,data,caf,amr,truehd,dts,mpegps,avi,asf,loas
  --enable-muxer=mp4,mov,ipod,matroska,webm,matroska_audio,ogg,opus,oga,mp3,flac,wav,adts,mpegts,flv,ffmetadata,image2,mjpeg,webvtt,srt,ass,null,h264,hevc,ivf,caf,data
  --enable-decoder=aac,aac_latm,opus,vorbis,mp3,mp3float,mp2,flac,alac,ac3,eac3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,pcm_mulaw,pcm_alaw,truehd,dca,amrnb,amrwb,h264,hevc,vp8,vp9,av1,mpeg4,mjpeg,png,webp,gif,bmp,webvtt,subrip,srt,ass,ssa,movtext,text
  --enable-encoder=aac,libmp3lame,libopus,flac,alac,pcm_s16le,mjpeg,png,webvtt,subrip,srt,ass,ssa,movtext
  --enable-parser=aac,aac_latm,ac3,opus,vorbis,mpegaudio,flac,h264,hevc,vp8,vp9,av1,mjpeg,png,webp,gif,dca
  --enable-bsfs
  --enable-filter=aresample,aformat,anull,null,format,scale,setpts,asetpts,copy,acopy,crop,trim,atrim
  --enable-swscale --enable-swresample
  --disable-avdevice
)
build_platform() { # sdk target-triple name
  local SDK=$1 TRIPLE=$2 NAME=$3
  local CMAKE_SYS=iOS; [ "$SDK" = macosx ] && CMAKE_SYS=Darwin
  local SYSROOT; SYSROOT=$(xcrun -sdk "$SDK" --show-sdk-path)
  local CC; CC=$(xcrun -sdk "$SDK" -f clang)
  local PREFIX="$BUILD/$NAME/prefix"
  local CFLAGS="-target $TRIPLE -isysroot $SYSROOT -Os -fPIC"
  mkdir -p "$PREFIX"

  if [ ! -f "$PREFIX/lib/libmp3lame.a" ]; then
    echo "== LAME ($NAME)"
    rm -rf "$BUILD/$NAME/lame"; cp -R "$VENDOR/lame-$LAME_VER" "$BUILD/$NAME/lame"
    (cd "$BUILD/$NAME/lame" &&
      ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-frontend --disable-decoder CC="$CC" CFLAGS="$CFLAGS -DSTDC_HEADERS=1" LDFLAGS="-target $TRIPLE -isysroot $SYSROOT" >/dev/null &&
      make -j"$JOBS" >/dev/null && make install >/dev/null) || exit 1
  fi

  if [ ! -f "$PREFIX/lib/libmbedtls.a" ]; then
    echo "== mbedTLS ($NAME)"
    rm -rf "$BUILD/$NAME/mbedtls"
    cmake -S "$VENDOR/mbedtls-$MBEDTLS_VER" -B "$BUILD/$NAME/mbedtls" \
      -DCMAKE_SYSTEM_NAME=$CMAKE_SYS -DCMAKE_OSX_SYSROOT="$SYSROOT" -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_C_FLAGS="-target $TRIPLE" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
      -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON >/dev/null
    cmake --build "$BUILD/$NAME/mbedtls" -j"$JOBS" >/dev/null
    cmake --install "$BUILD/$NAME/mbedtls" >/dev/null
  fi

  if [ ! -f "$PREFIX/lib/libopus.a" ]; then
    echo "== libopus ($NAME)"
    rm -rf "$BUILD/$NAME/opus"; cp -R "$VENDOR/opus-$OPUS_VER" "$BUILD/$NAME/opus"
    (cd "$BUILD/$NAME/opus" &&
      ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-doc --disable-extra-programs --disable-dred --disable-deep-plc --disable-osce \
        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="-target $TRIPLE -isysroot $SYSROOT" >/dev/null &&
      make -j"$JOBS" >/dev/null && make install >/dev/null) || exit 1
  fi

  local INPROC="-DALEMBIC_IN_PROCESS"; [ "$SDK" = macosx ] && INPROC=""
  local FFB="$BUILD/$NAME/ffmpeg"
  if [ ! -f "$FFB/ffprobe_g" ]; then
    echo "== FFmpeg ($NAME) — this takes a few minutes"
    rm -rf "$FFB"; mkdir -p "$FFB"
    (cd "$FFB" && PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH= "$FFSRC/configure" \
      --prefix="$PREFIX" --enable-cross-compile --target-os=darwin --arch=aarch64 \
      --cc="$CC" --sysroot="$SYSROOT" \
      --extra-cflags="$CFLAGS $INPROC -I$PREFIX/include" \
      --pkg-config-flags=--static \
      --extra-ldflags="-target $TRIPLE -isysroot $SYSROOT -L$PREFIX/lib" \
      --enable-static --disable-shared --enable-pic --disable-debug --disable-doc --enable-small \
      --disable-ffplay --enable-ffmpeg --enable-ffprobe \
      --disable-sdl2 --disable-xlib --disable-libxcb \
      --disable-appkit --disable-coreimage --disable-metal --disable-avfoundation \
      --disable-videotoolbox --disable-audiotoolbox \
      "${COMPONENTS[@]}" \
      --enable-libmp3lame --enable-libopus --enable-mbedtls --enable-version3 \
      --enable-zlib --enable-bzlib --enable-iconv >"$FFB/configure.log" 2>&1) \
      || { tail -30 "$FFB/config.log"; exit 1; }
    (cd "$FFB" && make -j"$JOBS" V=1 >"$FFB/make.log" 2>&1) || { grep -m5 "error:" "$FFB/make.log"; exit 1; }
  fi
}

framework() { # name platform-name dylib-path -> $BUILD/<platform>/fw/<name>.framework
  local NAME=$1 PLAT=$2 DYLIB=$3
  local FW="$BUILD/$PLAT/fw/$NAME.framework"
  rm -rf "$FW"; mkdir -p "$FW"
  cp "$DYLIB" "$FW/$NAME"
  cat > "$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>app.alembic.$NAME</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$FFMPEG_VER</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>$MIN_IOS</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict></plist>
EOF
}

link_platform() { # sdk triple name
  local SDK=$1 TRIPLE=$2 NAME=$3
  local SYSROOT; SYSROOT=$(xcrun -sdk "$SDK" --show-sdk-path)
  local CC; CC=$(xcrun -sdk "$SDK" -f clang)
  local FFB="$BUILD/$NAME/ffmpeg" PREFIX="$BUILD/$NAME/prefix" L="$BUILD/$NAME/link"
  mkdir -p "$L"
  # libswscale's framepool.o is the same code as libavfilter's (it #includes it); keep one copy.
  cp "$FFB/libswscale/libswscale.a" "$L/libswscale.a"
  ar d "$L/libswscale.a" framepool.o 2>/dev/null || true
  local LIBS="$FFB/libavfilter/libavfilter.a $FFB/libavformat/libavformat.a \
    $FFB/libavcodec/libavcodec.a $FFB/libswresample/libswresample.a $L/libswscale.a \
    $FFB/libavutil/libavutil.a $PREFIX/lib/libmp3lame.a $PREFIX/lib/libopus.a $PREFIX/lib/libmbedtls.a $PREFIX/lib/libmbedx509.a \
    $PREFIX/lib/libmbedcrypto.a"
  local SYS="-framework CoreFoundation -framework Security -lz -lbz2 -liconv"

  echo "== Linking frameworks ($NAME)"
  "$CC" -target "$TRIPLE" -isysroot "$SYSROOT" -dynamiclib -o "$L/FFmpegCore" \
    -Wl,-all_load $LIBS $SYS -install_name @rpath/FFmpegCore.framework/FFmpegCore -Wl,-dead_strip_dylibs -Wl,-x
  framework FFmpegCore "$NAME" "$L/FFmpegCore"

  # Tool object lists come straight from FFmpeg's own link lines.
  for tool in ffmpeg ffprobe; do
    local objs
    objs=$(grep -E -- "-o ${tool}_g " "$FFB/make.log" | tail -1 | tr ' ' '\n' | grep -E '^fftools/.*\.o$' | sed "s|^|$FFB/|" | tr '\n' ' ')
    [ -n "$objs" ] || { echo "could not find link line for $tool"; exit 1; }
    local FWNAME; [ $tool = ffmpeg ] && FWNAME=FFmpegTool || FWNAME=FFprobeTool
    "$CC" -target "$TRIPLE" -isysroot "$SYSROOT" -dynamiclib -o "$L/$FWNAME" $objs \
      -F"$BUILD/$NAME/fw" -framework FFmpegCore $SYS \
      -install_name "@rpath/$FWNAME.framework/$FWNAME" -Wl,-x
    framework "$FWNAME" "$NAME" "$L/$FWNAME"
  done
}

build_platform macosx "arm64-apple-macos13.0" macos
mkdir -p "$BUILD/macos/bin"
cp "$BUILD/macos/ffmpeg/ffmpeg" "$BUILD/macos/ffmpeg/ffprobe" "$BUILD/macos/bin/"
build_platform iphoneos "arm64-apple-ios$MIN_IOS" device
build_platform iphonesimulator "arm64-apple-ios$MIN_IOS-simulator" simulator
link_platform iphoneos "arm64-apple-ios$MIN_IOS" device
link_platform iphonesimulator "arm64-apple-ios$MIN_IOS-simulator" simulator

mkdir -p "$OUT"
for fw in FFmpegCore FFmpegTool FFprobeTool; do
  rm -rf "$OUT/$fw.xcframework"
  xcodebuild -create-xcframework \
    -framework "$BUILD/device/fw/$fw.framework" \
    -framework "$BUILD/simulator/fw/$fw.framework" \
    -output "$OUT/$fw.xcframework" >/dev/null
done
# Headers aren't needed by the app (it only calls `main`), but keep the licences with the binaries.
cp "$FFSRC/COPYING.LGPLv3" "$OUT/FFMPEG-LICENSE.txt"
cp "$VENDOR/opus-$OPUS_VER/COPYING" "$OUT/OPUS-LICENSE.txt"
echo "Done: $OUT"; du -sh "$OUT"/*.xcframework
