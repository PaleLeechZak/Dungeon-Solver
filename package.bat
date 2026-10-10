@echo off
rem Builds the game and packages it, one zip per platform:
rem   build\dungeon-solver-windows.zip
rem   build\dungeon-solver-linux.zip
rem
rem   package.bat            both
rem   package.bat windows    only the Windows zip
rem   package.bat linux      only the Linux zip (needs WSL, see build_linux.bat)
rem
rem What goes in is decided by the config and the two manifests it names
rem (config\models.json5 and config\sounds.json5): the files they list, what
rem those files need, the fonts and UI kit pieces, and the licence files that
rem sit beside them. The data is the same in both zips; only the program
rem differs. Each staged copy is checked by loading everything the game loads
rem at start-up from it before it is zipped. The game is not run.
setlocal
cd /d "%~dp0"

set WHAT=%1
if "%WHAT%"=="" set WHAT=both
if /i not "%WHAT%"=="both" if /i not "%WHAT%"=="windows" if /i not "%WHAT%"=="linux" (
	echo usage: package.bat [both^|windows^|linux]
	exit /b 2
)

if /i not "%WHAT%"=="linux" call :windows || exit /b 1
if /i not "%WHAT%"=="windows" call :linux || exit /b 1
exit /b 0

:windows
rem By full path: a bare "build.bat" can resolve to some other build.bat on PATH.
rem The same goes for tar further down: Git ships a tar that cannot write zips.
call "%~dp0build.bat" || exit /b 1
odin run src\pack -out:build\pack.exe -- build\package\windows\dungeon-solver windows config/dungeon.json5 build || exit /b 1
if exist build\dungeon-solver-windows.zip del build\dungeon-solver-windows.zip
"%SystemRoot%\System32\tar.exe" -a -c --options zip:compression=deflate -f build\dungeon-solver-windows.zip -C build\package\windows dungeon-solver || exit /b 1
echo Packaged build\dungeon-solver-windows.zip
exit /b 0

:linux
call "%~dp0build_linux.bat" || exit /b 1
odin run src\pack -out:build\pack.exe -- build\package\linux\dungeon-solver linux config/dungeon.json5 build/linux || exit /b 1
rem Zipped on the Linux side so the game keeps its executable bit.
call "%~dp0build_linux.bat" archive build/package/linux/dungeon-solver build/dungeon-solver-linux.zip || exit /b 1
echo Packaged build\dungeon-solver-linux.zip
exit /b 0
