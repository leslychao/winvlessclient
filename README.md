# winvlessclient (Windows 11)

Minimal desktop client with:
- VLESS URL input (`vless://...`)
- editable primary domain list in UI (one domain per line)
- `Connect` / `Disconnect`
- start/stop `sing-box.exe`
- status + logs
- local profile save
- selective VPN via `sing-box` TUN mode

## Quick start

1. Run `start.cmd`.
2. If `runtime/sing-box.exe` is missing, it will be downloaded automatically (latest Windows x64 release).
3. Paste your `vless://...` URL.
4. Click `Connect`.
5. Click `Disconnect` when done.

## Notes

- Run as **Administrator** (`tun` requires elevated rights).
- This app uses `sing-box` TUN mode, not browser/system proxy mode.
- Enter only primary domains (for example `youtube.com` and `chatgpt.com`).
- On connect, the app dynamically discovers related domains (DNS CNAME + page host extraction) and routes them via VPN.
- All traffic outside discovered domain suffixes goes direct.
- Profile is saved to `runtime/profile.json`.
- Runtime config is generated at `runtime/config.json`.

## Structure

- `vless-client.ps1` - UI layer and event handlers.
- `lib/bootstrap.ps1` - runtime paths, state, job-object interop.
- `lib/core.ps1` - domain processing, config generation, profile and log helpers.
- `lib/process.ps1` - process-to-job binding helpers.
