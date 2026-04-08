@echo off
setlocal
cd /d "%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList '-ExecutionPolicy Bypass -File ""%~dp0vless-client.ps1""'"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File ".\vless-client.ps1"
