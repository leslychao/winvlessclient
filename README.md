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
- `sing-box` path is fixed to `runtime/sing-box.exe` and is not editable in UI.
- Split tunneling is done by `sing-box` route rules on the client (`tun` + domain rules).
- Built-in proxy domain coverage includes: `youtube.com`, `youtu.be`, `googlevideo.com`, `ytimg.com`, `openai.com`, `chatgpt.com`, `oaistatic.com`.
- Traffic for domains outside the configured domain rules goes `direct`.
- Sensitive connection data is saved to `runtime/connection.private.json` (ignored by git).
- Domain list and routing preferences are saved to `settings.json` (project root).
- Legacy `runtime/profile.json` is migrated automatically and removed.
- Runtime config is generated at `runtime/config.json`.

## Structure

- `vless-client.ps1` - UI layer and event handlers.
- `lib/bootstrap.ps1` - runtime paths, state, job-object interop.
- `lib/core.ps1` - domain processing, config generation, profile and log helpers.
- `lib/process.ps1` - process-to-job binding helpers.
