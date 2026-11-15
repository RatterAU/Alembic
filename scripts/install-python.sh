#!/usr/bin/env bash
# Xcode build phase: puts Python, the engine and yt-dlp into the app bundle.
#  - Python stdlib from BeeWare's support package, minus what Alembic never uses
#  - each compiled stdlib module wrapped as a framework (the iOS requirement),
#    following BeeWare's own utils.sh
#  - engine/ (our Python), app_packages/ (mutagen, certifi) and yt-dlp.zip,
#    all prepared and verified by scripts/fetch-engine.sh
set -euo pipefail
APP="$CODESIGNING_FOLDER_PATH"
XCF="$PROJECT_DIR/vendor/python/Python.xcframework"
ENGINE_BUILD="$PROJECT_DIR/build/engine"
[ -f "$ENGINE_BUILD/yt-dlp.zip" ] || { echo "error: run scripts/fetch-engine.sh first"; exit 1; }

if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then SLICE=ios-arm64_x86_64-simulator; else SLICE=ios-arm64; fi
LIB="$APP/python/lib"
mkdir -p "$LIB"
rsync -a --delete "$XCF/lib/" "$LIB/" --exclude 'libpython*.dylib'
ARCH=$(echo $ARCHS | awk '{print $1}')
rsync -a "$XCF/$SLICE/lib-$ARCH/" "$LIB/" --exclude 'libpython*.dylib'
PY=$(ls -1 "$LIB" | grep -E '^python3\.[0-9]+$')
STD="$LIB/$PY"

# Lean: drop what an iOS downloader never imports.
( cd "$STD"
  rm -rf test idlelib tkinter turtledemo turtle.py ensurepip lib2to3 pydoc_data venv \
         unittest/test sqlite3/test ctypes/test distutils/tests __phello__ \
         site-packages/* config-* curses dbm/sqlite3.py \
         doctest.py pydoc.py tabnanny.py pdb.py profile.py cProfile.py \
         xmlrpc wsgiref unittest _pyrepl multiprocessing _pydecimal.py pickletools.py \
         idlelib turtle.py 2>/dev/null || true
  find . -name "__pycache__" -type d -prune -exec rm -rf {} +
  cd lib-dynload
  rm -f _test*.so _xxtestfuzz*.so xxlimited*.so xxsubtype*.so _ctypes_test*.so \
        _curses*.so _tkinter*.so _dbm*.so _gdbm*.so readline*.so \
        _interpreters*.so _interpqueues*.so _interpchannels*.so _testinternalcapi*.so 2>/dev/null || true
)

# Wrap each .so as a framework, as iOS requires (BeeWare's install_dylib, adapted:
# ad-hoc signed when no signing identity is set, e.g. for unsigned IPAs).
find "$STD/lib-dynload" -name "*.so" | while read -r FULL_EXT; do
  EXT=$(basename "$FULL_EXT")
  MODULE=$(echo "$EXT" | cut -d "." -f 1)
  REL=${FULL_EXT#$APP/}
  FW="Frameworks/$MODULE.framework"
  mkdir -p "$APP/$FW"
  cp "$XCF/build/iOS-dylib-Info-template.plist" "$APP/$FW/Info.plist"
  plutil -replace CFBundleExecutable -string "$MODULE" "$APP/$FW/Info.plist"
  plutil -replace CFBundleIdentifier -string "$(echo "$PRODUCT_BUNDLE_IDENTIFIER.$MODULE" | tr '_' '-')" "$APP/$FW/Info.plist"
  mv "$FULL_EXT" "$APP/$FW/$MODULE"
  echo "$FW/$MODULE" > "${FULL_EXT%.so}.fwork"
  echo "${REL%.so}.fwork" > "$APP/$FW/$MODULE.origin"
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$APP/$FW" >/dev/null 2>&1 || true
done

# Our Python and its verified dependencies
rsync -a --delete --exclude '__pycache__' --exclude 'tests' "$PROJECT_DIR/Engine/engine/" "$APP/engine/"
rsync -a --delete "$ENGINE_BUILD/app_packages/" "$APP/app_packages/"
cp "$ENGINE_BUILD/yt-dlp.zip" "$APP/yt-dlp.zip"
echo "Python $PY installed: $(du -sh "$APP/python" | cut -f1)"
