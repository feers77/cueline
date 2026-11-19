@echo off
rem Cueline Builder -- build the Windows one-file exe yourself (pinned: CPython 3.13.x, PyInstaller 6.11.1).
rem Run from the repository's builder\ folder, with builder\cueline.delta present (from the release or mkdelta.py).
cd /d %~dp0
set PYTHONHASHSEED=0
set SOURCE_DATE_EPOCH=1763294400
if not exist venv\Scripts\python.exe py -3.13 -m venv venv
venv\Scripts\python.exe -m pip install --disable-pip-version-check -q pyinstaller==6.11.1
venv\Scripts\python.exe -m PyInstaller --noconfirm --clean --onefile --noconsole --name CuelineBuilder ^
  --add-data "cueline.delta;." --add-data "..\scripts\firmware\gui_decode.py;codec" ^
  --add-data "..\scripts\firmware\gui_encode.py;codec" --add-data "..\scripts\firmware\main_decode.py;codec" ^
  --add-data "..\scripts\firmware\main_encode.py;codec" --add-data "..\scripts\firmware\lzss_decode.py;codec" ^
  --add-data "..\scripts\firmware\lzss_encode.py;codec" --paths ..\scripts\firmware ^
  --hidden-import gui_decode --hidden-import gui_encode --hidden-import main_decode --hidden-import main_encode ^
  --hidden-import lzss_decode --hidden-import lzss_encode cueline_patch.py
echo exit %ERRORLEVEL%  (exe: dist\CuelineBuilder.exe)
