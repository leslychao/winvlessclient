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

function Write-JsonNoBom([string]$path, [object]$value, [int]$depth) {
    Write-TextNoBom -path $path -content ($value | ConvertTo-Json -Depth $depth)
}

function Get-DefaultVpnDomains {
    return @(
        "youtube.com",
        "youtu.be",
        "googlevideo.com",
        "ytimg.com",
        "openai.com",
        "chatgpt.com",
        "oaistatic.com"
    )
}

function Normalize-DomainEntry([string]$rawDomain) {
    if ([string]::IsNullOrWhiteSpace($rawDomain)) { return $null }

    $item = $rawDomain.Trim().ToLowerInvariant()
    if ($item -match "\s") { throw "Invalid VPN domain '$rawDomain': spaces are not allowed." }

    if ($item.StartsWith("http://") -or $item.StartsWith("https://")) {
        $uri = $null
        if (-not [System.Uri]::TryCreate($item, [System.UriKind]::Absolute, [ref]$uri)) {
            throw "Invalid VPN domain '$rawDomain': URL is not valid."
        }
        if ($uri.Authority -match ":\d+$") {
            throw "Invalid VPN domain '$rawDomain': ports are not allowed."
        }
        $item = $uri.Host
    } else {
        $item = ($item -split "[/?#]", 2)[0]
        if ($item -match ":\d+$") {
            throw "Invalid VPN domain '$rawDomain': ports are not allowed."
        }
    }

    if ($item.StartsWith("*.")) { $item = $item.Substring(2) }
    $item = $item.TrimEnd([char]'.')
    if ([string]::IsNullOrWhiteSpace($item)) { return $null }
    if ($item.Contains("*")) { throw "Invalid VPN domain '$rawDomain': wildcards are only allowed as a leading '*.' prefix." }
    if ($item.Length -gt 253) { throw "Invalid VPN domain '$rawDomain': domain is too long." }
    if ($item.StartsWith(".") -or $item.EndsWith(".")) { throw "Invalid VPN domain '$rawDomain': empty labels are not allowed." }
    if ($item -notmatch "^[a-z0-9.-]+$") { throw "Invalid VPN domain '$rawDomain': only ASCII letters, digits, dots and hyphens are allowed." }

    foreach ($label in ($item -split "\.")) {
        if ([string]::IsNullOrWhiteSpace($label)) { throw "Invalid VPN domain '$rawDomain': empty labels are not allowed." }
        if ($label.Length -gt 63) { throw "Invalid VPN domain '$rawDomain': label '$label' is too long." }
        if ($label.StartsWith("-") -or $label.EndsWith("-")) { throw "Invalid VPN domain '$rawDomain': label '$label' starts or ends with '-'." }
    }

    return $item
}

function Get-NormalizedDomainArray([string[]]$domains) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($d in $domains) {
        $domain = Normalize-DomainEntry ([string]$d)
        if ([string]::IsNullOrWhiteSpace($domain)) { continue }
        if ($set.Add($domain)) { $result.Add($domain) }
    }
    return $result.ToArray()
}

function Get-NormalizedDomainList([string]$rawText) {
    if ([string]::IsNullOrWhiteSpace($rawText)) { return @() }
    return Get-NormalizedDomainArray ($rawText -split "\r?\n|\r")
}

function Merge-RequiredVpnDomains([string[]]$domains) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Get-NormalizedDomainArray $domains)) {
        if ($set.Add($d)) { $result.Add($d) }
    }
    foreach ($required in (Get-DefaultVpnDomains)) {
        if ($set.Add($required)) { $result.Add($required) }
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
            $lines = $chunk -split "\r?\n|\r"
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
        $key = [System.Uri]::UnescapeDataString($parts[0].Replace("+", "%20")).Trim().ToLowerInvariant()
        $value = ""
        if ($parts.Length -gt 1) { $value = [System.Uri]::UnescapeDataString($parts[1].Replace("+", "%20")) }
        if ([string]::IsNullOrWhiteSpace($key)) { throw "VLESS URL contains an empty query parameter name." }
        $result[$key] = $value
    }
    return $result
}

function Get-QueryValue([hashtable]$params, [string]$key, [string]$defaultValue) {
    if ($params.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$params[$key])) {
        return [string]$params[$key]
    }
    return $defaultValue
}

function Get-NormalizedQueryValue([hashtable]$params, [string]$key, [string]$defaultValue) {
    return (Get-QueryValue $params $key $defaultValue).Trim().ToLowerInvariant()
}

function Validate-TransportPath([string]$path, [string]$defaultValue) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $defaultValue }
    $trimmed = $path.Trim()
    if (-not $trimmed.StartsWith("/")) { throw "Transport path must start with '/'." }
    return $trimmed
}

function Get-OptionalHost([hashtable]$params) {
    $transportHost = Get-QueryValue $params "host" ""
    if ([string]::IsNullOrWhiteSpace($transportHost)) { return "" }
    return Normalize-DomainEntry $transportHost
}

function Build-SingBoxConfigFromVless([string]$vlessUrl, [string[]]$vpnDomains, [bool]$routeAllTraffic = $false) {
    if ([string]::IsNullOrWhiteSpace($vlessUrl)) { throw "VLESS URL is empty." }
    $trimmed = $vlessUrl.Trim()
    $uri = $null
    if (-not [System.Uri]::TryCreate($trimmed, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "VLESS URL is not valid."
    }
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($uri.Scheme, "vless")) {
        throw "VLESS URL must start with vless://"
    }
    $params = Parse-Query $uri.Query

    $uuid = [System.Uri]::UnescapeDataString($uri.UserInfo)
    if ([string]::IsNullOrWhiteSpace($uuid)) { throw "UUID is missing in vless:// URL" }
    $parsedUuid = [Guid]::Empty
    if (-not [Guid]::TryParse($uuid, [ref]$parsedUuid)) { throw "UUID is not valid in vless:// URL" }
    if ([string]::IsNullOrWhiteSpace($uri.Host)) { throw "Server host is missing in vless:// URL" }
    if ($uri.Port -le 0) { throw "Server port is missing in vless:// URL" }

    $security = Get-NormalizedQueryValue $params "security" "tls"
    $transportType = Get-NormalizedQueryValue $params "type" "tcp"
    if (@("tls", "reality", "none") -notcontains $security) {
        throw "Unsupported VLESS security '$security'. Supported values: tls, reality, none."
    }
    if (@("tcp", "ws", "grpc", "http", "httpupgrade", "quic") -notcontains $transportType) {
        throw "Unsupported VLESS transport '$transportType'. Supported values: tcp, ws, grpc, http, httpupgrade, quic."
    }

    $flow = Get-QueryValue $params "flow" ""
    if (-not [string]::IsNullOrWhiteSpace($flow) -and $flow -ne "xtls-rprx-vision") {
        throw "Unsupported VLESS flow '$flow'. Supported value: xtls-rprx-vision."
    }

    $tls = @{ enabled = $true; server_name = $uri.Host }
    if ($params.ContainsKey("sni") -and -not [string]::IsNullOrWhiteSpace($params["sni"])) { $tls.server_name = Normalize-DomainEntry ([string]$params["sni"]) }
    if ($params.ContainsKey("fp") -and -not [string]::IsNullOrWhiteSpace($params["fp"])) {
        $tls.utls = @{ enabled = $true; fingerprint = ([string]$params["fp"]).Trim().ToLowerInvariant() }
    }
    if ($security -eq "reality") {
        if (-not $params.ContainsKey("pbk") -or [string]::IsNullOrWhiteSpace($params["pbk"])) {
            throw "For security=reality, pbk query param is required"
        }
        $tls.reality = @{ enabled = $true; public_key = ([string]$params["pbk"]).Trim() }
        if ($params.ContainsKey("sid") -and -not [string]::IsNullOrWhiteSpace($params["sid"])) { $tls.reality.short_id = ([string]$params["sid"]).Trim() }
    } elseif ($security -eq "none") {
        if ($params.ContainsKey("sni") -or $params.ContainsKey("fp") -or $params.ContainsKey("pbk") -or $params.ContainsKey("sid")) {
            throw "TLS/Reality parameters cannot be used when security=none."
        }
        $tls.enabled = $false
        $tls.Remove("server_name")
    }

    $outbound = @{
        type = "vless"; tag = "vless-out"; server = $uri.Host; server_port = $uri.Port; uuid = $parsedUuid.ToString()
    }
    if (-not [string]::IsNullOrWhiteSpace($flow)) { $outbound.flow = $flow }
    if ($tls.enabled) { $outbound.tls = $tls }

    switch ($transportType) {
        "tcp" {}
        "ws" {
            $path = Validate-TransportPath (Get-QueryValue $params "path" "/") "/"
            $transport = @{ type = "ws"; path = $path }
            $transportHost = Get-OptionalHost $params
            if (-not [string]::IsNullOrWhiteSpace($transportHost)) {
                $transport.headers = @{ Host = $transportHost }
            }
            $outbound.transport = $transport
        }
        "grpc" {
            $serviceName = if ($params.ContainsKey("servicename")) { [string]$params["servicename"] } elseif ($params.ContainsKey("service_name")) { [string]$params["service_name"] } else { "" }
            $transport = @{ type = "grpc" }
            if (-not [string]::IsNullOrWhiteSpace($serviceName)) { $transport.service_name = $serviceName.Trim() }
            $outbound.transport = $transport
        }
        "http" {
            $transport = @{ type = "http" }
            $path = Validate-TransportPath (Get-QueryValue $params "path" "") ""
            if (-not [string]::IsNullOrWhiteSpace($path)) { $transport.path = $path }
            $transportHost = Get-OptionalHost $params
            if (-not [string]::IsNullOrWhiteSpace($transportHost)) { $transport.host = @($transportHost) }
            $outbound.transport = $transport
        }
        "httpupgrade" {
            $transport = @{ type = "httpupgrade"; path = (Validate-TransportPath (Get-QueryValue $params "path" "/") "/") }
            $transportHost = Get-OptionalHost $params
            if (-not [string]::IsNullOrWhiteSpace($transportHost)) { $transport.host = $transportHost }
            $outbound.transport = $transport
        }
        "quic" {
            $outbound.transport = @{ type = "quic" }
        }
    }

    $normalizedDomains = Get-NormalizedDomainArray $vpnDomains
    if (-not $routeAllTraffic -and (-not $normalizedDomains -or $normalizedDomains.Count -eq 0)) {
        throw "VPN domain list is empty."
    }

    $dnsRules = @()
    $routeRules = @(
        @{ action = "sniff" },
        @{ port = 53; action = "hijack-dns" },
        @{ protocol = "dns"; action = "hijack-dns" }
    )
    $dnsFinal = "dns-local"
    $routeFinal = "direct"
    if ($routeAllTraffic) {
        $dnsFinal = "dns-remote"
        $routeFinal = "vless-out"
        $routeRules += @{ ip_is_private = $true; outbound = "direct" }
    } else {
        $dnsRules += @{ domain_suffix = $normalizedDomains; server = "dns-remote" }
        $routeRules += @{ domain_suffix = $normalizedDomains; outbound = "vless-out" }
    }

    return @{
        log = @{ level = "info"; timestamp = $true; output = $script:SingBoxLogPath }
        dns = @{
            servers = @(
                @{ type = "https"; tag = "dns-remote"; server = "1.1.1.1"; server_port = 443; path = "/dns-query"; detour = "vless-out" },
                @{ type = "udp"; tag = "dns-local"; server = "8.8.8.8"; server_port = 53 }
            )
            rules = $dnsRules
            final = $dnsFinal
            strategy = "prefer_ipv4"
            independent_cache = $true
            reverse_mapping = $true
        }
        inbounds = @(
            @{ type = "tun"; tag = "tun-in"; interface_name = "sb-vpn"; address = @("172.19.0.1/30"); mtu = 1500; auto_route = $true; strict_route = $false; stack = "mixed" }
        )
        outbounds = @(
            $outbound,
            @{ type = "direct"; tag = "direct" }
        )
        route = @{ final = $routeFinal; auto_detect_interface = $true; default_domain_resolver = "dns-local"; rules = $routeRules }
    }
}

function Assert-SingBoxConfigValid([string]$singboxPath, [string]$configPath) {
    if ([string]::IsNullOrWhiteSpace($singboxPath) -or -not (Test-Path $singboxPath)) {
        throw "sing-box.exe not found: $singboxPath"
    }
    if ([string]::IsNullOrWhiteSpace($configPath) -or -not (Test-Path $configPath)) {
        throw "sing-box config not found: $configPath"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $singboxPath
    $psi.Arguments = ('check -c "{0}"' -f ($configPath -replace '"', '\"'))
    $psi.WorkingDirectory = $script:AppRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw "Failed to start sing-box config validation." }
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit(15000)) {
        try { $proc.Kill() } catch {}
        throw "sing-box config validation timed out."
    }
    if ($proc.ExitCode -ne 0) {
        $details = (($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($details)) { $details = "exit code " + $proc.ExitCode }
        throw "sing-box config validation failed: $details"
    }
    return $true
}

function Get-DefaultClientProfile {
    $defaultSingboxPath = Join-Path $script:RuntimeDir "sing-box.exe"
    return @{
        singbox_path = $defaultSingboxPath
        vless_url = ""
        primary_domains_text = (Get-DefaultVpnDomains) -join [Environment]::NewLine
        route_all_traffic = $false
    }
}

function Save-ConnectionProfile([string]$vlessUrl) {
    Write-JsonNoBom -path $script:ConnectionProfilePath -value @{
            vless_url = $vlessUrl
        } -depth 4
}

function Save-SettingsProfile([string]$primaryDomainsText, [bool]$routeAllTraffic = $false) {
    $vpnDomains = Merge-RequiredVpnDomains (Get-NormalizedDomainList $primaryDomainsText)
    Write-JsonNoBom -path $script:SettingsPath -value @{
            vpn_domains = @($vpnDomains)
            route_all_traffic = $routeAllTraffic
        } -depth 4
}

function Save-Profile([hashtable]$profile) {
    Save-ConnectionProfile ([string]$profile.vless_url)
    Save-SettingsProfile ([string]$profile.primary_domains_text) ([bool]$profile.route_all_traffic)
}

function Try-MigrateLegacyProfile {
    $legacyPath = Join-Path $script:RuntimeDir "profile.json"
    if (-not (Test-Path $legacyPath)) { return }
    try {
        $legacy = (Get-Content -Path $legacyPath -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch {
        return
    }

    $needConnectionMigration = -not (Test-Path $script:ConnectionProfilePath)
    $needSettingsMigration = -not (Test-Path $script:SettingsPath)
    if ($needConnectionMigration) {
        Save-ConnectionProfile ([string]$legacy.vless_url)
    }
    if ($needSettingsMigration) {
        Save-SettingsProfile ([string]$legacy.primary_domains_text) (Get-BooleanProperty $legacy "route_all_traffic" $false)
    }

    try {
        Remove-Item -Path $legacyPath -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Read-DomainSettingsText([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { return $null }
    $settings = (Get-Content -Path $path -Raw -Encoding UTF8) | ConvertFrom-Json
    if (-not $settings.vpn_domains) { return $null }
    $domains = Get-NormalizedDomainArray @($settings.vpn_domains)
    if (-not $domains -or $domains.Count -eq 0) { return $null }
    return ($domains -join [Environment]::NewLine)
}

function Get-BooleanProperty([object]$settings, [string]$name, [bool]$defaultValue) {
    if (-not $settings -or -not ($settings.PSObject.Properties.Name -contains $name)) { return $defaultValue }
    $value = $settings.$name
    if ($null -eq $value) { return $defaultValue }
    if ($value -is [bool]) { return [bool]$value }

    $parsed = $false
    $text = ([string]$value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $defaultValue }
    if ([bool]::TryParse($text, [ref]$parsed)) { return $parsed }
    throw "Invalid boolean setting '$name'."
}

function Read-RouteAllTrafficSetting([string]$path, [bool]$defaultValue) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { return $defaultValue }
    $settings = (Get-Content -Path $path -Raw -Encoding UTF8) | ConvertFrom-Json
    return Get-BooleanProperty $settings "route_all_traffic" $defaultValue
}

function Load-Profile {
    $default = Get-DefaultClientProfile
    Try-MigrateLegacyProfile

    $vlessUrl = ""
    if (Test-Path $script:ConnectionProfilePath) {
        try {
            $connection = (Get-Content -Path $script:ConnectionProfilePath -Raw -Encoding UTF8) | ConvertFrom-Json
            $vlessUrl = [string]$connection.vless_url
        } catch {}
    }

    $primaryText = $default.primary_domains_text
    $routeAllTraffic = [bool]$default.route_all_traffic
    if (Test-Path $script:SettingsPath) {
        try {
            $runtimeText = Read-DomainSettingsText $script:SettingsPath
            if (-not [string]::IsNullOrWhiteSpace($runtimeText)) { $primaryText = $runtimeText }
            $routeAllTraffic = Read-RouteAllTrafficSetting $script:SettingsPath $false
        } catch {
            Append-FileLog ("Runtime settings ignored: " + $_.Exception.Message)
        }
    } elseif ($script:SeedSettingsPath -and (Test-Path $script:SeedSettingsPath)) {
        try {
            $seedText = Read-DomainSettingsText $script:SeedSettingsPath
            if (-not [string]::IsNullOrWhiteSpace($seedText)) { $primaryText = $seedText }
            $routeAllTraffic = Read-RouteAllTrafficSetting $script:SeedSettingsPath $false
        } catch {
            Append-FileLog ("Seed settings ignored: " + $_.Exception.Message)
        }
    }

    return @{
        singbox_path = $default.singbox_path
        vless_url = $vlessUrl
        primary_domains_text = $primaryText
        route_all_traffic = $routeAllTraffic
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
