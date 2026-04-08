function Append-FileLog([string]$message) {
    try {
        Rotate-LogFile -path $script:ClientLogPath -maxBytes $script:ClientLogMaxBytes -backupCount $script:LogBackupCount | Out-Null
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $message
        Add-Content -Path $script:ClientLogPath -Value $line -Encoding UTF8
    } catch {}
}

function Rotate-LogFile([string]$path, [long]$maxBytes, [int]$backupCount) {
    try {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { return $false }
        $item = Get-Item -Path $path -ErrorAction SilentlyContinue
        if (-not $item -or $item.Length -le $maxBytes) { return $false }

        for ($i = $backupCount; $i -ge 1; $i--) {
            $src = "{0}.{1}" -f $path, $i
            $dst = "{0}.{1}" -f $path, ($i + 1)
            if (Test-Path $src) {
                if ($i -eq $backupCount) {
                    Remove-Item -Path $src -Force -ErrorAction SilentlyContinue
                } else {
                    Move-Item -Path $src -Destination $dst -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Move-Item -Path $path -Destination ("{0}.1" -f $path) -Force -ErrorAction Stop
        New-Item -Path $path -ItemType File -Force | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Write-TextNoBom([string]$path, [string]$content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
}

function Get-DefaultVpnDomains {
    return @("youtube.com", "chatgpt.com")
}

function Get-NormalizedDomainList([string]$rawText) {
    $result = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($rawText)) { return @() }
    $lines = $rawText -split "(`r`n|`n|`r)"
    foreach ($line in $lines) {
        $item = $line.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        if ($item.StartsWith("http://")) { $item = $item.Substring(7) }
        if ($item.StartsWith("https://")) { $item = $item.Substring(8) }
        if ($item.EndsWith("/")) { $item = $item.TrimEnd("/") }
        if ($item.Contains("/")) { $item = $item.Split("/", 2)[0] }
        if (-not [string]::IsNullOrWhiteSpace($item) -and -not $result.Contains($item)) {
            $result.Add($item)
        }
    }
    return $result.ToArray()
}

function Get-EffectiveDomainSuffix([string]$host) {
    if ([string]::IsNullOrWhiteSpace($host)) { return "" }
    $labels = $host.Split(".") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($labels.Count -lt 2) { return $host }
    if ($labels.Count -ge 3 -and $labels[$labels.Count - 1].Length -eq 2 -and $labels[$labels.Count - 2].Length -le 3) {
        return (($labels[($labels.Count - 3)..($labels.Count - 1)]) -join ".")
    }
    return (($labels[($labels.Count - 2)..($labels.Count - 1)]) -join ".")
}

function Expand-VpnDomainGroups([string[]]$domains) {
    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $domains) {
        if (-not [string]::IsNullOrWhiteSpace($d) -and $seen.Add($d)) { $result.Add($d) }
    }

    $candidates = New-Object System.Collections.Generic.Queue[string]
    foreach ($d in $domains) {
        $candidates.Enqueue($d)
        $candidates.Enqueue("www.$d")
    }

    $iterations = 0
    while ($candidates.Count -gt 0 -and $iterations -lt 40 -and $result.Count -lt 120) {
        $iterations++
        $current = $candidates.Dequeue()
        if ([string]::IsNullOrWhiteSpace($current)) { continue }

        try {
            $records = Resolve-DnsName -Name $current -Type CNAME -ErrorAction SilentlyContinue
            foreach ($rec in $records) {
                if (-not $rec.NameHost) { continue }
                $host = ([string]$rec.NameHost).Trim().TrimEnd(".").ToLowerInvariant()
                if ($seen.Add($host)) { $result.Add($host) }
                $suffix = Get-EffectiveDomainSuffix $host
                if (-not [string]::IsNullOrWhiteSpace($suffix) -and $seen.Add($suffix)) {
                    $result.Add($suffix)
                    $candidates.Enqueue($suffix)
                    $candidates.Enqueue("www.$suffix")
                }
            }
        } catch {}

        try {
            $resp = Invoke-WebRequest -Uri ("https://{0}" -f $current) -Method Get -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($resp -and $resp.Content) {
                $matches = [regex]::Matches($resp.Content, 'https?://([a-z0-9.-]+\.[a-z]{2,})')
                $bare = [regex]::Matches($resp.Content, '(?<![a-z0-9-])([a-z0-9-]+(?:\.[a-z0-9-]+)+\.[a-z]{2,24})(?![a-z0-9-])')
                $allMatches = New-Object System.Collections.Generic.List[System.Text.RegularExpressions.Match]
                foreach ($m in $matches) { $allMatches.Add($m) }
                foreach ($m in $bare) { $allMatches.Add($m) }
                $added = 0
                foreach ($m in $allMatches) {
                    if ($m.Groups.Count -lt 2) { continue }
                    $host = $m.Groups[1].Value.Trim().ToLowerInvariant()
                    if ([string]::IsNullOrWhiteSpace($host)) { continue }
                    if ($seen.Add($host)) {
                        $result.Add($host)
                        $added++
                    }
                    $suffix = Get-EffectiveDomainSuffix $host
                    if (-not [string]::IsNullOrWhiteSpace($suffix) -and $seen.Add($suffix)) {
                        $result.Add($suffix)
                        $candidates.Enqueue($suffix)
                    }
                    if ($added -ge 30) { break }
                }
            }
        } catch {}
    }
    return $result.ToArray()
}

function Read-SingBoxLogDelta {
    try {
        if (-not (Test-Path $script:SingBoxLogPath)) {
            $script:LastSingBoxLogOffset = 0
            return
        }
        $rotated = Rotate-LogFile -path $script:SingBoxLogPath -maxBytes $script:SingBoxLogMaxBytes -backupCount $script:LogBackupCount
        if ($rotated) {
            $script:LastSingBoxLogOffset = 0
            return
        }

        $len = (Get-Item -Path $script:SingBoxLogPath -ErrorAction SilentlyContinue).Length
        if ($null -eq $len) { return }
        if ($len -lt $script:LastSingBoxLogOffset) { $script:LastSingBoxLogOffset = 0 }
        if ($len -eq $script:LastSingBoxLogOffset) { return }

        $fs = [System.IO.File]::Open($script:SingBoxLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            [void]$fs.Seek($script:LastSingBoxLogOffset, [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 1024, $true)
            try {
                $chunk = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
            $script:LastSingBoxLogOffset = $fs.Position
        } finally {
            $fs.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($chunk)) {
            $lines = $chunk -split "(`r`n|`n|`r)"
            foreach ($raw in $lines) {
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                $clean = ([string]$raw) -replace '\x1b\[[0-9;]*m', ''
                Append-Log ("sing-box: " + $clean)
            }
        }
    } catch {
        Append-FileLog ("Read sing-box log error: " + $_.Exception.Message)
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Parse-Query([string]$queryString) {
    $result = @{}
    if ([string]::IsNullOrWhiteSpace($queryString)) { return $result }
    $clean = $queryString.TrimStart("?")
    if ([string]::IsNullOrWhiteSpace($clean)) { return $result }
    foreach ($pair in $clean.Split("&")) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair.Split("=", 2)
        $key = [System.Uri]::UnescapeDataString($parts[0])
        $value = ""
        if ($parts.Length -gt 1) { $value = [System.Uri]::UnescapeDataString($parts[1]) }
        $result[$key] = $value
    }
    return $result
}

function Build-SingBoxConfigFromVless([string]$vlessUrl, [string[]]$vpnDomains) {
    $trimmed = $vlessUrl.Trim()
    if (-not $trimmed.StartsWith("vless://")) { throw "VLESS URL must start with vless://" }
    $uri = [Uri]$trimmed
    $params = Parse-Query $uri.Query

    $uuid = $uri.UserInfo
    if ([string]::IsNullOrWhiteSpace($uuid)) { throw "UUID is missing in vless:// URL" }
    if ([string]::IsNullOrWhiteSpace($uri.Host)) { throw "Server host is missing in vless:// URL" }
    if ($uri.Port -le 0) { throw "Server port is missing in vless:// URL" }

    $security = if ($params.ContainsKey("security") -and -not [string]::IsNullOrWhiteSpace($params["security"])) { $params["security"] } else { "tls" }
    $transportType = if ($params.ContainsKey("type") -and -not [string]::IsNullOrWhiteSpace($params["type"])) { $params["type"] } else { "tcp" }

    $tls = @{ enabled = $true; server_name = $uri.Host }
    if ($params.ContainsKey("sni") -and -not [string]::IsNullOrWhiteSpace($params["sni"])) { $tls.server_name = $params["sni"] }
    if ($params.ContainsKey("fp") -and -not [string]::IsNullOrWhiteSpace($params["fp"])) {
        $tls.utls = @{ enabled = $true; fingerprint = $params["fp"] }
    }
    if ($security -eq "reality") {
        if (-not $params.ContainsKey("pbk") -or [string]::IsNullOrWhiteSpace($params["pbk"])) {
            throw "For security=reality, pbk query param is required"
        }
        $tls.reality = @{ enabled = $true; public_key = $params["pbk"] }
        if ($params.ContainsKey("sid") -and -not [string]::IsNullOrWhiteSpace($params["sid"])) { $tls.reality.short_id = $params["sid"] }
    } elseif ($security -eq "none") {
        $tls.enabled = $false
        $tls.Remove("server_name")
    }

    $outbound = @{
        type = "vless"; tag = "vless-out"; server = $uri.Host; server_port = $uri.Port; uuid = $uuid
    }
    if ($params.ContainsKey("flow") -and -not [string]::IsNullOrWhiteSpace($params["flow"])) { $outbound.flow = $params["flow"] }
    if ($tls.enabled) { $outbound.tls = $tls }

    switch ($transportType) {
        "ws" {
            $path = if ($params.ContainsKey("path") -and -not [string]::IsNullOrWhiteSpace($params["path"])) { $params["path"] } else { "/" }
            $transport = @{ type = "ws"; path = $path }
            if ($params.ContainsKey("host") -and -not [string]::IsNullOrWhiteSpace($params["host"])) {
                $transport.headers = @{ Host = $params["host"] }
            }
            $outbound.transport = $transport
        }
        "grpc" {
            $serviceName = if ($params.ContainsKey("serviceName")) { $params["serviceName"] } elseif ($params.ContainsKey("service_name")) { $params["service_name"] } else { "" }
            $transport = @{ type = "grpc" }
            if (-not [string]::IsNullOrWhiteSpace($serviceName)) { $transport.service_name = $serviceName }
            $outbound.transport = $transport
        }
    }

    $dnsRules = @()
    $routeRules = @(
        @{ action = "sniff" },
        @{ port = 53; action = "hijack-dns" },
        @{ protocol = "dns"; action = "hijack-dns" }
    )
    if ($vpnDomains -and $vpnDomains.Count -gt 0) {
        $dnsRules += @{ domain_suffix = $vpnDomains; server = "dns-remote" }
        $routeRules += @{ domain_suffix = $vpnDomains; outbound = "vless-out" }
    }

    return @{
        log = @{ level = "info"; timestamp = $true; output = $script:SingBoxLogPath }
        dns = @{
            servers = @(
                @{ type = "https"; tag = "dns-remote"; server = "1.1.1.1"; server_port = 443; path = "/dns-query"; detour = "vless-out" },
                @{ type = "udp"; tag = "dns-local"; server = "8.8.8.8"; server_port = 53 }
            )
            rules = $dnsRules
            final = "dns-local"
            strategy = "prefer_ipv4"
            independent_cache = $true
            reverse_mapping = $true
        }
        inbounds = @(
            @{ type = "tun"; tag = "tun-in"; interface_name = "sb-vpn"; address = @("172.19.0.1/30"); mtu = 9000; auto_route = $true; strict_route = $true; stack = "mixed" }
        )
        outbounds = @(
            $outbound,
            @{ type = "direct"; tag = "direct" }
        )
        route = @{ final = "direct"; auto_detect_interface = $true; default_domain_resolver = "dns-local"; rules = $routeRules }
    }
}

function Save-Profile([hashtable]$profile) {
    Write-TextNoBom -path $script:ProfilePath -content ($profile | ConvertTo-Json -Depth 6)
}

function Load-Profile {
    $defaultSingboxPath = Join-Path $script:RuntimeDir "sing-box.exe"
    if (-not (Test-Path $script:ProfilePath)) {
        return @{ singbox_path = $defaultSingboxPath; vless_url = ""; primary_domains_text = (Get-DefaultVpnDomains) -join [Environment]::NewLine }
    }
    try {
        $obj = (Get-Content -Path $script:ProfilePath -Raw -Encoding UTF8) | ConvertFrom-Json
        $primaryText = [string]$obj.primary_domains_text
        if ([string]::IsNullOrWhiteSpace($primaryText)) { $primaryText = (Get-DefaultVpnDomains) -join [Environment]::NewLine }
        $singboxPath = [string]$obj.singbox_path
        if ([string]::IsNullOrWhiteSpace($singboxPath)) {
            $singboxPath = $defaultSingboxPath
        }
        return @{ singbox_path = $singboxPath; vless_url = [string]$obj.vless_url; primary_domains_text = $primaryText }
    } catch {
        return @{ singbox_path = $defaultSingboxPath; vless_url = ""; primary_domains_text = (Get-DefaultVpnDomains) -join [Environment]::NewLine }
    }
}

function Stop-SingBox {
    if ($script:ProcessRef -and -not $script:ProcessRef.HasExited) {
        try {
            $script:ProcessRef.Kill()
            $script:ProcessRef.WaitForExit(3000) | Out-Null
        } catch {}
    }
    $script:ProcessRef = $null
}

function Stop-OrphanSingBox([string]$expectedExePath) {
    if ([string]::IsNullOrWhiteSpace($expectedExePath) -or -not (Test-Path $expectedExePath)) { return 0 }
    $normalizedExpected = [System.IO.Path]::GetFullPath($expectedExePath)
    $killed = 0
    $all = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
    foreach ($proc in $all) {
        try {
            if ($script:ProcessRef -and -not $script:ProcessRef.HasExited -and $proc.Id -eq $script:ProcessRef.Id) { continue }
            $procPath = $proc.Path
            if ([string]::IsNullOrWhiteSpace($procPath)) { continue }
            $normalizedProcPath = [System.IO.Path]::GetFullPath($procPath)
            if ([System.StringComparer]::OrdinalIgnoreCase.Equals($normalizedExpected, $normalizedProcPath)) {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                $killed++
            }
        } catch {
            Append-FileLog ("Failed to stop orphan PID " + $proc.Id + ": " + $_.Exception.Message)
        }
    }
    return $killed
}
