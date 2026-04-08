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

1. Put `sing-box.exe` into this folder  
   (or set the full path in the app field).
2. Run `start.cmd`.
3. Paste your `vless://...` URL.
4. Click `Connect`.
5. Click `Disconnect` when done.

## Notes

- Run as **Administrator** (`tun` requires elevated rights).
- This app uses `sing-box` TUN mode, not browser/system proxy mode.
- Enter only primary domains (for example `youtube.com` and `chatgpt.com`).
- On connect, the app dynamically discovers related domains (DNS CNAME + page host extraction) and routes them via VPN.
- All traffic outside discovered domain suffixes goes direct.
- Profile is saved to `profile.json`.
- Runtime config is generated at `runtime/config.json`.

## Structure

- `vless-client.ps1` - UI layer and event handlers.
- `lib/bootstrap.ps1` - runtime paths, state, job-object interop.
- `lib/core.ps1` - domain processing, config generation, profile and log helpers.
- `lib/process.ps1` - process-to-job binding helpers.
