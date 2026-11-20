#!/bin/bash
# build_app.sh: build CuelineBuilder.app for macOS (Intel + Apple Silicon) from builder/ and scripts/firmware/.
# Uses Apple's Python (/usr/bin/python3, universal2) in a private venv and a pinned PyInstaller.
# Output: dist/CuelineBuilder.app and dist/CuelineBuilder-macOS.zip (the zip keeps the app's signature).
set -e
cd "$(dirname "$0")"
export PYTHONHASHSEED=0 SOURCE_DATE_EPOCH=1763294400
[ -x venv-mac/bin/python ] || /usr/bin/python3 -m venv venv-mac
venv-mac/bin/python -m pip install --disable-pip-version-check -q pyinstaller==6.11.1
F=../scripts/firmware
venv-mac/bin/python -m PyInstaller --noconfirm --clean --windowed --argv-emulation --target-arch universal2 \
  --name CuelineBuilder --osx-bundle-identifier org.cueline.builder \
  --add-data "cueline.delta:." --add-data "$F/gui_decode.py:codec" --add-data "$F/gui_encode.py:codec" \
  --add-data "$F/main_decode.py:codec" --add-data "$F/main_encode.py:codec" \
  --add-data "$F/lzss_decode.py:codec" --add-data "$F/lzss_encode.py:codec" --paths "$F" \
  --hidden-import gui_decode --hidden-import gui_encode --hidden-import main_decode --hidden-import main_encode \
  --hidden-import lzss_decode --hidden-import lzss_encode cueline_patch.py
codesign --force --deep -s - dist/CuelineBuilder.app        # ad-hoc signature (required on Apple Silicon)
rm -f dist/CuelineBuilder-macOS.zip
ditto -c -k --keepParent dist/CuelineBuilder.app dist/CuelineBuilder-macOS.zip
echo "app: dist/CuelineBuilder.app  zip: dist/CuelineBuilder-macOS.zip"
