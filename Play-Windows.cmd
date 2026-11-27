@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if not errorlevel 1 (
  py -3 multiplayer\open_client.py %*
) else (
  python multiplayer\open_client.py %*
)
if errorlevel 1 pause
