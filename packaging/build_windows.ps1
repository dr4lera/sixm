$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
Set-Location $project
python -m pip install --disable-pip-version-check pyinstaller==6.22.3
if ($LASTEXITCODE -ne 0) { throw 'PyInstaller installation failed' }
python -B -m unittest discover -s multiplayer/tests -v
if ($LASTEXITCODE -ne 0) { throw 'Server tests failed' }
python -m PyInstaller --noconfirm --clean --onefile --console --name Sixm --distpath build/windows --workpath build/pyinstaller-client --specpath build multiplayer/open_client.py
if ($LASTEXITCODE -ne 0) { throw 'Client build failed' }
python -m PyInstaller --noconfirm --clean --onefile --console --name SixmServer --distpath build/windows --workpath build/pyinstaller-server --specpath build --add-data "$project/multiplayer/client;client" --add-data "$project/multiplayer/maps;maps" multiplayer/server.py
if ($LASTEXITCODE -ne 0) { throw 'Server build failed' }
python packaging/smoke_windows.py
if ($LASTEXITCODE -ne 0) { throw 'Packaged executable smoke test failed' }
Copy-Item packaging/WINDOWS.txt build/windows/README.txt
Compress-Archive -Path build/windows/Sixm.exe,build/windows/SixmServer.exe,build/windows/README.txt -DestinationPath build/Sixm-Windows-x64.zip -Force
New-Item -ItemType Directory -Force build/release | Out-Null
Copy-Item build/windows/Sixm.exe,build/windows/SixmServer.exe,build/Sixm-Windows-x64.zip build/release/
Get-FileHash build/windows/Sixm.exe,build/windows/SixmServer.exe,build/Sixm-Windows-x64.zip -Algorithm SHA256 | Format-Table
