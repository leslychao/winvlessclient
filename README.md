# winvlessclient (Windows 11)

Current version: 1.1.0.

Minimal desktop client with:
- VLESS URL input (`vless://...`)
- editable primary domain list in UI (one domain per line)
- `Connect` / `Disconnect`
- start/stop `sing-box.exe`
- status + logs
- local profile save
- selective VPN via `sing-box` TUN mode
- optional full VPN mode for all public internet traffic

## Quick start

1. Run `start.cmd`.
2. If `runtime/sing-box.exe` is missing or not the pinned version, `start.cmd` downloads the pinned Windows x64 release (`sing-box` 1.13.6).
3. Paste your `vless://...` URL.
4. Click `Connect`.
5. Click `Disconnect` when done.

## Notes

- Run as **Administrator** (`tun` requires elevated rights).
- This app uses `sing-box` TUN mode, not browser/system proxy mode.
- `sing-box` path is fixed to `runtime/sing-box.exe` and is not editable in UI.
- Split tunneling is done by `sing-box` route rules on the client (`tun` + domain rules).
- `Route all traffic through VPN` routes public internet traffic through VLESS and keeps private/LAN IP ranges direct.
- Built-in proxy domain coverage includes: `youtube.com`, `youtu.be`, `googlevideo.com`, `ytimg.com`, `openai.com`, `chatgpt.com`, `oaistatic.com`.
- Domain entries are canonicalized before routing: `*.example.com` is stored and routed as `example.com` because `domain_suffix` already matches subdomains.
- In selective mode, traffic for domains outside the configured domain rules goes `direct`.
- Sensitive connection data is saved to `runtime/connection.private.json` (ignored by git).
- The project-root `settings.json` is a tracked seed/default domain list. User-edited runtime domain preferences are saved to `runtime/settings.json` (ignored by git).
- Legacy `runtime/profile.json` is migrated automatically and removed.
- Runtime config is generated at `runtime/config.json`.
- Supported VLESS URL transports are `tcp`, `ws`, `grpc`, `http`, `httpupgrade`, and `quic`; unsupported `security`, `type`, `flow`, UUID, host or port values are rejected before `sing-box` starts.

## Structure

- `vless-client.ps1` - UI layer and event handlers.
- `lib/bootstrap.ps1` - runtime paths, state, job-object interop.
- `lib/core.ps1` - domain processing, config generation, profile and log helpers.
- `lib/process.ps1` - process-to-job binding helpers.
