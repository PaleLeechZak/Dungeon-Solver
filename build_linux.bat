@echo off
rem Builds the game for Linux from Windows, through WSL.
rem   build_linux.bat            optimised build  -> build\linux\dungeon
rem   build_linux.bat debug      debug build
rem   build_linux.bat test       run every test package on Linux
rem
rem Uses the default WSL distribution; set WSL_DISTRO to choose another, e.g.
rem   set WSL_DISTRO=Debian
rem The real work is in build_linux.sh, which says what the distribution has
rem to have installed if anything is missing. The game is not run.
setlocal
where wsl >nul 2>nul || (echo WSL is not installed. See: wsl --install & exit /b 1)

set DISTRO=
if defined WSL_DISTRO set DISTRO=-d %WSL_DISTRO%

wsl %DISTRO% --cd "%~dp0." -e bash ./build_linux.sh %* || exit /b 1
