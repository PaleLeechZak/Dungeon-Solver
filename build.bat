@echo off
rem Builds build\dungeon.exe. It does not run it.
rem   build.bat           optimised build
rem   build.bat debug     debug build with GPU validation
setlocal
cd /d "%~dp0"
if not exist build mkdir build

set FLAGS=-o:speed
if /i "%1"=="debug" set FLAGS=-debug

odin build src\game -out:build\dungeon.exe -vet -strict-style %FLAGS% || exit /b 1

for /f "delims=" %%R in ('odin root') do set ODIN_ROOT_DIR=%%R
copy /y "%ODIN_ROOT_DIR%vendor\sdl3\SDL3.dll" build\ >nul || exit /b 1

echo Built build\dungeon.exe. Start it from this folder: build\dungeon.exe [config path]
