@echo off
rem Runs every test package. Nothing here opens a window or needs a GPU.
setlocal
cd /d "%~dp0"
if not exist build mkdir build

rem The game package links SDL3, so its test binary needs the DLL beside it.
for /f "delims=" %%R in ('odin root') do set ODIN_ROOT_DIR=%%R
copy /y "%ODIN_ROOT_DIR%vendor\sdl3\SDL3.dll" build\ >nul || exit /b 1

for %%P in (dungeon camera assets input ui hud sound menu bundle game) do (
	echo === %%P ===
	odin test src\%%P -out:build\%%P_test.exe -vet -strict-style || exit /b 1
)
echo All test packages passed.
