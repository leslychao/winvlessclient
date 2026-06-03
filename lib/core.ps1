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
        if ($set.Contains($domain)) { continue }

        $covered = $false
        foreach ($existing in $result) {
            if (Test-DomainSuffixCovers $existing $domain) {
                $covered = $true
                break
            }
        }
        if ($covered) { continue }

        for ($i = $result.Count - 1; $i -ge 0; $i--) {
            $existing = [string]$result[$i]
            if (Test-DomainSuffixCovers $domain $existing) {
                [void]$set.Remove($existing)
                $result.RemoveAt($i)
            }
        }

        if ($set.Add($domain)) { $result.Add($domain) }
    }
    return $result.ToArray()
}

function Get-NormalizedDomainList([string]$rawText) {
    if ([string]::IsNullOrWhiteSpace($rawText)) { return @() }
    return Get-NormalizedDomainArray ($rawText -split "\r?\n|\r")
}

function Test-DomainSuffixCovers([string]$suffix, [string]$domain) {
    if ([string]::IsNullOrWhiteSpace($suffix) -or [string]::IsNullOrWhiteSpace($domain)) { return $false }
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($suffix, $domain)) { return $true }
    return $domain.EndsWith("." + $suffix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Merge-RequiredVpnDomains([string[]]$domains) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Get-NormalizedDomainArray $domains)) {
        if ($set.Add($d)) { $result.Add($d) }
    }
    foreach ($required in (Get-RequiredVpnDomains)) {
        if ($set.Add($required)) { $result.Add($required) }
    }
    return $result.ToArray()
}

function Get-ObjectPropertyValue([object]$value, [string[]]$propertyNames) {
    if ($null -eq $value) { return $null }
    foreach ($propertyName in $propertyNames) {
        if ([string]::IsNullOrWhiteSpace($propertyName)) { continue }
        if ($value -is [hashtable] -and $value.ContainsKey($propertyName)) {
            return $value[$propertyName]
        }
        $property = $value.PSObject.Properties[$propertyName]
        if ($property) { return $property.Value }
    }
    return $null
}

function Normalize-CountryCode([object]$countryCode) {
    if ($null -eq $countryCode) { return "" }
    $normalized = ([string]$countryCode).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return "" }
    if ($normalized -eq "UK") { return "GB" }
    if ($normalized -notmatch "^[A-Z]{2}$") {
        throw "External IP diagnostic response does not include a two-letter country code."
    }
    return $normalized
}

function Get-OpenAiSupportedCountryCodeSet {
    if ($script:OpenAiSupportedCountryCodeSet) { return $script:OpenAiSupportedCountryCodeSet }

    # Source: https://help.openai.com/en/articles/8983035, checked 2026-06-02.
    $codes = @(
        "AF", "AL", "DZ", "AD", "AO", "AG", "AR", "AM", "AU", "AT", "AZ", "BS", "BH", "BD", "BB", "BE",
        "BZ", "BJ", "BT", "BO", "BA", "BW", "BR", "BN", "BG", "BF", "BI", "CV", "KH", "CM", "CA", "CF",
        "TD", "CL", "CO", "KM", "CG", "CD", "CR", "CI", "HR", "CY", "CZ", "DK", "DJ", "DM", "DO", "EC",
        "EG", "SV", "GQ", "ER", "EE", "SZ", "ET", "FJ", "FI", "FR", "GA", "GM", "GE", "DE", "GH", "GR",
        "GD", "GT", "GN", "GW", "GY", "HT", "VA", "HN", "HU", "IS", "IN", "ID", "IQ", "IE", "IL", "IT",
        "JM", "JP", "JO", "KZ", "KE", "KI", "KW", "KG", "LA", "LV", "LB", "LS", "LR", "LY", "LI", "LT",
        "LU", "MG", "MW", "MY", "MV", "ML", "MT", "MH", "MR", "MU", "MX", "FM", "MD", "MC", "MN", "ME",
        "MA", "MZ", "MM", "NA", "NR", "NP", "NL", "NZ", "NI", "NE", "NG", "MK", "NO", "OM", "PK", "PW",
        "PS", "PA", "PG", "PY", "PE", "PH", "PL", "PT", "QA", "RO", "RW", "KN", "LC", "VC", "WS", "SM",
        "ST", "SA", "SN", "RS", "SC", "SL", "SG", "SK", "SI", "SB", "SO", "ZA", "KR", "SS", "ES", "LK",
        "SR", "SE", "CH", "SD", "TW", "TJ", "TZ", "TH", "TL", "TG", "TO", "TT", "TN", "TR", "TM", "TV",
        "UG", "UA", "AE", "GB", "US", "UY", "UZ", "VU", "VN", "YE", "ZM", "ZW"
    )

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($code in $codes) {
        [void]$set.Add($code)
    }
    $script:OpenAiSupportedCountryCodeSet = $set
    return $script:OpenAiSupportedCountryCodeSet
}

function Test-OpenAiSupportedCountry([string]$countryCode) {
    $normalized = Normalize-CountryCode $countryCode
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    return (Get-OpenAiSupportedCountryCodeSet).Contains($normalized)
}

function ConvertTo-ExitIpDiagnosticResult([object]$response) {
    $ip = ([string](Get-ObjectPropertyValue $response @("ip", "query", "address"))).Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw "External IP diagnostic response does not include an IP address."
    }

    $parsedIp = $null
    if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsedIp)) {
        throw "External IP diagnostic response contains an invalid IP address: $ip"
    }

    $country = Normalize-CountryCode (Get-ObjectPropertyValue $response @("country_code", "country_iso", "country"))
    if ([string]::IsNullOrWhiteSpace($country)) {
        throw "External IP diagnostic response does not include a country code."
    }

    return @{
        ip = $ip
        country = $country
        openai_supported = (Test-OpenAiSupportedCountry $country)
    }
}

function Format-ExitIpDiagnosticLogLines([object]$diagnostic) {
    $ip = ([string](Get-ObjectPropertyValue $diagnostic @("ip"))).Trim()
    $country = Normalize-CountryCode (Get-ObjectPropertyValue $diagnostic @("country"))
    $openAiSupportedValue = Get-ObjectPropertyValue $diagnostic @("openai_supported")
    $openAiSupported = if ($null -eq $openAiSupportedValue) { Test-OpenAiSupportedCountry $country } else { [bool]$openAiSupportedValue }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("External IP: {0}, country: {1}" -f $ip, $country))
    if (-not $openAiSupported) {
        $lines.Add("VLESS exit IP is not suitable for OpenAI")
    }
    return $lines.ToArray()
}

function Invoke-ExternalIpDiagnostic([int]$timeoutSec = 8) {
    $endpoints = @(
        @{ name = "ipinfo.io"; uri = "https://ipinfo.io/json" },
        @{ name = "ifconfig.co"; uri = "https://ifconfig.co/json" }
    )
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($endpoint in $endpoints) {
        try {
            $response = Invoke-RestMethod `
                -Uri ([string]$endpoint["uri"]) `
                -Method Get `
                -TimeoutSec $timeoutSec `
                -UseBasicParsing `
                -Headers @{ Accept = "application/json"; "User-Agent" = "winvlessclient" }
            return ConvertTo-ExitIpDiagnosticResult $response
        } catch {
            $errors.Add(("{0}: {1}" -f $endpoint["name"], $_.Exception.Message))
        }
    }

    throw ("no external IP endpoint returned usable data: " + ($errors -join "; "))
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

function Get-LegacyRoutePropertyValue([object]$object, [string]$name, [bool]$required = $true) {
    if ($object -is [hashtable]) {
        if ($object.ContainsKey($name)) { return $object[$name] }
    } elseif ($object -and ($object.PSObject.Properties.Name -contains $name)) {
        return $object.$name
    }

    if ($required) { throw "Legacy route state is missing '$name'." }
    return $null
}

function Get-LegacyRouteString([object]$route, [string]$name) {
    $value = Get-LegacyRoutePropertyValue $route $name
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Legacy route state has an empty '$name'."
    }
    return ([string]$value).Trim()
}

function Get-LegacyRouteInt([object]$route, [string]$name, [int]$minValue, [int]$maxValue) {
    $value = Get-LegacyRoutePropertyValue $route $name
    $parsed = 0
    if (-not [int]::TryParse(([string]$value).Trim(), [ref]$parsed) -or $parsed -lt $minValue -or $parsed -gt $maxValue) {
        throw "Legacy route state has an invalid '$name'."
    }
    return $parsed
}

function Get-LegacyRouteBool([object]$route, [string]$name, [bool]$defaultValue) {
    $value = Get-LegacyRoutePropertyValue $route $name $false
    if ($null -eq $value) { return $defaultValue }
    if ($value -is [bool]) { return [bool]$value }

    $parsed = $false
    if ([bool]::TryParse(([string]$value).Trim(), [ref]$parsed)) { return $parsed }
    throw "Legacy route state has an invalid '$name'."
}

function Test-IPv4Address([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($value.Trim(), [ref]$address)) { return $false }
    return ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

function Test-IPv4Cidr([string]$value, [int]$requiredPrefixLength = -1) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    $parts = $value.Trim().Split("/")
    if ($parts.Count -ne 2) { return $false }
    if (-not (Test-IPv4Address $parts[0])) { return $false }

    $prefixLength = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefixLength)) { return $false }
    if ($prefixLength -lt 0 -or $prefixLength -gt 32) { return $false }
    if ($requiredPrefixLength -ge 0 -and $prefixLength -ne $requiredPrefixLength) { return $false }
    return $true
}

function ConvertTo-ValidatedLegacyRouteState([object]$state) {
    if (-not $state) { throw "Legacy route state is empty." }

    $defaultRoutesValue = Get-LegacyRoutePropertyValue $state "default_routes" $false
    $hostRoutesValue = Get-LegacyRoutePropertyValue $state "host_routes" $false
    $defaultRoutes = if ($null -eq $defaultRoutesValue) { @() } else { @($defaultRoutesValue) }
    $hostRoutes = if ($null -eq $hostRoutesValue) { @() } else { @($hostRoutesValue) }
    if ($defaultRoutes.Count -eq 0 -and $hostRoutes.Count -eq 0) {
        throw "Legacy route state does not contain route entries."
    }

    $validatedDefaultRoutes = @()
    foreach ($route in $defaultRoutes) {
        $destinationPrefix = Get-LegacyRouteString $route "destination_prefix"
        if ($destinationPrefix -ne "0.0.0.0/0") {
            throw "Legacy default route destination_prefix must be 0.0.0.0/0."
        }

        $interfaceIndex = Get-LegacyRouteInt $route "interface_index" 1 ([int]::MaxValue)
        $nextHop = Get-LegacyRouteString $route "next_hop"
        if (-not (Test-IPv4Address $nextHop)) {
            throw "Legacy default route next_hop must be an IPv4 address."
        }

        $routeMetric = Get-LegacyRouteInt $route "route_metric" 0 65535
        $validatedDefaultRoutes += @{
            destination_prefix = $destinationPrefix
            interface_index = $interfaceIndex
            next_hop = $nextHop
            route_metric = $routeMetric
        }
    }

    $validatedHostRoutes = @()
    foreach ($route in $hostRoutes) {
        $destinationPrefix = Get-LegacyRouteString $route "destination_prefix"
        if (-not (Test-IPv4Cidr $destinationPrefix 32)) {
            throw "Legacy host route destination_prefix must be an IPv4 /32 prefix."
        }

        $interfaceIndex = Get-LegacyRouteInt $route "interface_index" 1 ([int]::MaxValue)
        $nextHop = Get-LegacyRouteString $route "next_hop"
        if (-not (Test-IPv4Address $nextHop)) {
            throw "Legacy host route next_hop must be an IPv4 address."
        }

        $validatedHostRoutes += @{
            destination_prefix = $destinationPrefix
            interface_index = $interfaceIndex
            next_hop = $nextHop
            created = (Get-LegacyRouteBool $route "created" $false)
        }
    }

    return @{
        default_routes = @($validatedDefaultRoutes)
        host_routes = @($validatedHostRoutes)
    }
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
            @{ type = "tun"; tag = "tun-in"; interface_name = "sb-vpn"; address = @("172.19.0.1/30"); mtu = 1500; auto_route = $true; strict_route = $routeAllTraffic; stack = "mixed" }
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
        primary_domains_text = (Get-RequiredVpnDomains) -join [Environment]::NewLine
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

function Read-DomainSettingsArray([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { return @() }
    $settings = (Get-Content -Path $path -Raw -Encoding UTF8) | ConvertFrom-Json
    if (-not $settings.vpn_domains) { return @() }
    return Get-NormalizedDomainArray @($settings.vpn_domains)
}

function Read-DomainSettingsText([string]$path) {
    $domains = @(Read-DomainSettingsArray $path)
    if (-not $domains -or $domains.Count -eq 0) { return $null }
    return ($domains -join [Environment]::NewLine)
}

function Get-RequiredVpnDomains {
    if ($script:SeedSettingsPath -and (Test-Path $script:SeedSettingsPath)) {
        try {
            $seedDomains = @(Read-DomainSettingsArray $script:SeedSettingsPath)
            if ($seedDomains.Count -gt 0) { return $seedDomains }
        } catch {
            Append-FileLog ("Seed required domains ignored: " + $_.Exception.Message)
        }
    }
    return Get-DefaultVpnDomains
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
            $runtimeDomains = @(Read-DomainSettingsArray $script:SettingsPath)
            if ($runtimeDomains.Count -gt 0) {
                $primaryText = (Merge-RequiredVpnDomains $runtimeDomains) -join [Environment]::NewLine
            }
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
