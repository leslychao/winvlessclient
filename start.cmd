@echo off
setlocal
cd /d "%~dp0"

if not exist ".\runtime" (
  mkdir ".\runtime"
)

if not exist ".\runtime\sing-box.exe" (
  echo sing-box.exe not found. Downloading latest Windows x64 release...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ErrorActionPreference='Stop';" ^
    "$api='https://api.github.com/repos/SagerNet/sing-box/releases/latest';" ^
    "$release=Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent'='winvlessclient' };" ^
    "$asset=$release.assets | Where-Object { $_.name -match 'windows-amd64\.zip$' } | Select-Object -First 1;" ^
    "if(-not $asset){ throw 'Windows amd64 asset not found in latest release'; };" ^
    "$zip=Join-Path (Get-Location) 'sing-box.zip';" ^
    "$tmp=Join-Path (Get-Location) '.singbox-extract';" ^
    "if(Test-Path $zip){ Remove-Item $zip -Force };" ^
    "if(Test-Path $tmp){ Remove-Item $tmp -Recurse -Force };" ^
    "Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip;" ^
    "Expand-Archive -Path $zip -DestinationPath $tmp -Force;" ^
    "$exe=Get-ChildItem -Path $tmp -Recurse -Filter 'sing-box.exe' | Select-Object -First 1;" ^
    "if(-not $exe){ throw 'sing-box.exe not found after extraction'; };" ^
    "Copy-Item -Path $exe.FullName -Destination (Join-Path (Join-Path (Get-Location) 'runtime') 'sing-box.exe') -Force;" ^
    "Remove-Item $zip -Force;" ^
    "Remove-Item $tmp -Recurse -Force;"
  if errorlevel 1 (
    echo Failed to download sing-box.exe
    pause
    exit /b 1
  )
  echo runtime\sing-box.exe downloaded successfully.
)

net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -WindowStyle Hidden -FilePath 'powershell' -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0vless-client.ps1""'"
  exit /b
)
powershell -NoProfile -Command "Start-Process -WindowStyle Hidden -FilePath 'powershell' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0vless-client.ps1""'"
exit /b
