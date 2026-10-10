@echo off
rem Compiles the HLSL sources into every format SDL's GPU backends accept.
rem Needs SDL_shadercross (https://github.com/libsdl-org/SDL_shadercross) on PATH.
rem The outputs in shaders\compiled are embedded into the game with #load, so
rem rebuild the game after running this.
setlocal
cd /d "%~dp0"
if not exist compiled mkdir compiled

for %%S in (tile.vert tile.frag ui.vert ui.frag) do (
	shadercross %%S.hlsl -o compiled\%%S.spv || exit /b 1
	shadercross %%S.hlsl -o compiled\%%S.dxil || exit /b 1
	shadercross %%S.hlsl -o compiled\%%S.msl || exit /b 1
)
echo Shaders compiled.
