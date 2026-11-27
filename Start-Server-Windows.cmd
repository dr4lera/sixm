@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if not errorlevel 1 (
  py -3 multiplayer\server.py %*
) else (
  python multiplayer\server.py %*
)
if errorlevel 1 pause
