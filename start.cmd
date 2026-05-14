@echo off
setlocal
cd /d "%~dp0"

set "SING_BOX_VERSION=1.13.6"

if not exist ".\runtime" (
  mkdir ".\runtime"
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$version='%SING_BOX_VERSION%';" ^
  "$runtime=Join-Path (Get-Location) 'runtime';" ^
  "$exe=Join-Path $runtime 'sing-box.exe';" ^
  "function Test-SingBoxVersion([string]$path,[string]$expected){ if(-not (Test-Path $path)){ return $false }; $line=(& $path version 2>$null | Select-Object -First 1); if($LASTEXITCODE -ne 0){ return $false }; return ($line -eq ('sing-box version ' + $expected)) };" ^
  "if(Test-SingBoxVersion $exe $version){ Write-Host ('runtime\sing-box.exe pinned version ' + $version + ' is ready.'); exit 0 };" ^
  "if(Test-Path $exe){ Write-Host ('Replacing runtime\sing-box.exe with pinned version ' + $version); Remove-Item $exe -Force } else { Write-Host ('sing-box.exe not found. Downloading pinned Windows x64 release ' + $version + '...') };" ^
  "$file='sing-box-' + $version + '-windows-amd64.zip';" ^
  "$url='https://github.com/SagerNet/sing-box/releases/download/v' + $version + '/' + $file;" ^
  "$zip=Join-Path (Get-Location) $file;" ^
  "$tmp=Join-Path (Get-Location) '.singbox-extract';" ^
  "try { if(Test-Path $zip){ Remove-Item $zip -Force }; if(Test-Path $tmp){ Remove-Item $tmp -Recurse -Force }; Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip; Expand-Archive -Path $zip -DestinationPath $tmp -Force; $found=Get-ChildItem -Path $tmp -Recurse -Filter 'sing-box.exe' | Select-Object -First 1; if(-not $found){ throw 'sing-box.exe not found after extraction' }; Copy-Item -Path $found.FullName -Destination $exe -Force; if(-not (Test-SingBoxVersion $exe $version)){ throw 'Downloaded sing-box.exe version mismatch' }; Write-Host ('runtime\sing-box.exe downloaded successfully: ' + $version) } finally { if(Test-Path $zip){ Remove-Item $zip -Force -ErrorAction SilentlyContinue }; if(Test-Path $tmp){ Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } }"
if errorlevel 1 (
  echo Failed to prepare pinned sing-box.exe %SING_BOX_VERSION%
  pause
  exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0vless-client.ps1""'"
  exit /b
)
powershell -NoProfile -Command "Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0vless-client.ps1""'"
exit /b
