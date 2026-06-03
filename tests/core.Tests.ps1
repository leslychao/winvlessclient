$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $repoRoot "lib\core.ps1")

function Reset-TestPaths {
    $script:AppRoot = Join-Path $TestDrive "app"
    if (Test-Path $script:AppRoot) {
        Remove-Item -Path $script:AppRoot -Recurse -Force
    }
    $script:RuntimeDir = Join-Path $script:AppRoot "runtime"
    New-Item -Path $script:RuntimeDir -ItemType Directory -Force | Out-Null

    $script:ConnectionProfilePath = Join-Path $script:RuntimeDir "connection.private.json"
    $script:SeedSettingsPath = Join-Path $script:AppRoot "settings.json"
    $script:SettingsPath = Join-Path $script:RuntimeDir "settings.json"
    $script:ConfigPath = Join-Path $script:RuntimeDir "config.json"
    $script:ClientLogPath = Join-Path $script:RuntimeDir "client.log"
    $script:SingBoxLogPath = Join-Path $script:RuntimeDir "sing-box.log"
    $script:ClientLogMaxBytes = 1MB
    $script:SingBoxLogMaxBytes = 5MB
    $script:LogBackupCount = 3
}

Describe "Domain normalization" {
    BeforeEach {
        Reset-TestPaths
    }

    It "canonicalizes wildcards, URLs and duplicate domains" {
        $domains = Get-NormalizedDomainList " HTTPS://Example.COM/path`n*.Example.com`nfoo.com/abc`nFOO.com "

        ($domains -join ",") | Should Be "example.com,foo.com"
    }

    It "removes domains already covered by broader domain suffixes" {
        $domains = Get-NormalizedDomainList "api.openai.com`nOpenAI.com`nfoo.example.com`nbar.foo.example.com`n*.example.com`nexample.net`nnotexample.com"

        ($domains -join ",") | Should Be "openai.com,example.com,example.net,notexample.com"
    }

    It "rejects domains with ports or spaces" {
        { Get-NormalizedDomainList "example.com:443" } | Should Throw "ports are not allowed"
        { Get-NormalizedDomainList "bad domain.com" } | Should Throw "spaces are not allowed"
    }
}

Describe "VLESS config builder" {
    BeforeEach {
        Reset-TestPaths
    }

    It "rejects invalid UUID, security, transport and flow values" {
        { Build-SingBoxConfigFromVless "vless://not-a-uuid@example.com:443?security=tls&type=tcp" @("example.com") } | Should Throw "UUID is not valid"
        { Build-SingBoxConfigFromVless "vless://bf000d23-0752-40b4-affe-68f7707a9661@example.com:443?security=bogus&type=tcp" @("example.com") } | Should Throw "Unsupported VLESS security"
        { Build-SingBoxConfigFromVless "vless://bf000d23-0752-40b4-affe-68f7707a9661@example.com:443?security=tls&type=xhttp" @("example.com") } | Should Throw "Unsupported VLESS transport"
        { Build-SingBoxConfigFromVless "vless://bf000d23-0752-40b4-affe-68f7707a9661@example.com:443?security=tls&type=tcp&flow=bad" @("example.com") } | Should Throw "Unsupported VLESS flow"
    }

    It "maps supported transports without silent fallback" {
        $uuid = "bf000d23-0752-40b4-affe-68f7707a9661"
        $cases = @(
            @{ Type = "tcp"; Url = "vless://$uuid@example.com:443?security=tls&type=tcp"; Expected = "" },
            @{ Type = "ws"; Url = "vless://$uuid@example.com:443?security=tls&type=ws&path=%2Fws&host=cdn.example.com"; Expected = "ws" },
            @{ Type = "grpc"; Url = "vless://$uuid@example.com:443?security=tls&type=grpc&serviceName=TunService"; Expected = "grpc" },
            @{ Type = "http"; Url = "vless://$uuid@example.com:443?security=tls&type=http&path=%2Fh2&host=cdn.example.com"; Expected = "http" },
            @{ Type = "httpupgrade"; Url = "vless://$uuid@example.com:443?security=tls&type=httpupgrade&path=%2Fup&host=cdn.example.com"; Expected = "httpupgrade" },
            @{ Type = "quic"; Url = "vless://$uuid@example.com:443?security=tls&type=quic"; Expected = "quic" }
        )

        foreach ($case in $cases) {
            $config = Build-SingBoxConfigFromVless $case.Url @("*.Example.com")
            $outbound = @($config.outbounds)[0]
            $actual = if ($outbound.transport) { [string]$outbound.transport.type } else { "" }
            $actual | Should Be $case.Expected
            (@($config.route.rules[-1].domain_suffix) -join ",") | Should Be "example.com"
        }
    }

    It "builds selective and full VPN routing modes through the same config owner" {
        $uuid = "bf000d23-0752-40b4-affe-68f7707a9661"
        $url = "vless://$uuid@example.com:443?security=tls&type=tcp"

        $selective = Build-SingBoxConfigFromVless $url @("*.Example.com") $false
        $selective.dns.final | Should Be "dns-local"
        $selective.route.final | Should Be "direct"
        (@($selective.route.rules | Where-Object { $_.domain_suffix }).Count) | Should Be 1
        (@($selective.route.rules[-1].domain_suffix) -join ",") | Should Be "example.com"

        $full = Build-SingBoxConfigFromVless $url @() $true
        $full.dns.final | Should Be "dns-remote"
        $full.route.final | Should Be "vless-out"
        $full.inbounds[0].strict_route | Should Be $true
        (@($full.route.rules | Where-Object { $_.domain_suffix }).Count) | Should Be 0
        (@($full.route.rules | Where-Object { $_.ip_is_private -eq $true -and $_.outbound -eq "direct" }).Count) | Should Be 1
    }

    It "emits configs accepted by the pinned sing-box binary" {
        $singboxPath = Join-Path $repoRoot "runtime\sing-box.exe"
        $uuid = "bf000d23-0752-40b4-affe-68f7707a9661"
        $urls = @(
            "vless://$uuid@example.com:443?security=tls&type=tcp",
            "vless://$uuid@example.com:443?security=tls&type=ws&path=%2Fws&host=cdn.example.com",
            "vless://$uuid@example.com:443?security=tls&type=grpc&serviceName=TunService",
            "vless://$uuid@example.com:443?security=tls&type=http&path=%2Fh2&host=cdn.example.com",
            "vless://$uuid@example.com:443?security=tls&type=httpupgrade&path=%2Fup&host=cdn.example.com",
            "vless://$uuid@example.com:443?security=tls&type=quic"
        )

        foreach ($url in $urls) {
            foreach ($routeAllTraffic in @($false, $true)) {
                $config = Build-SingBoxConfigFromVless $url @("example.com") $routeAllTraffic
                Write-TextNoBom -path $script:ConfigPath -content ($config | ConvertTo-Json -Depth 20)
                { Assert-SingBoxConfigValid $singboxPath $script:ConfigPath } | Should Not Throw
            }
        }
    }
}

Describe "Full mode exit IP diagnostics" {
    BeforeEach {
        Reset-TestPaths
    }

    It "normalizes ipinfo.io JSON responses" {
        $diagnostic = ConvertTo-ExitIpDiagnosticResult ([pscustomobject]@{
                ip = "203.0.113.10"
                country = "US"
            })

        $diagnostic.ip | Should Be "203.0.113.10"
        $diagnostic.country | Should Be "US"
        $diagnostic.openai_supported | Should Be $true
    }

    It "normalizes ifconfig.co JSON responses" {
        $diagnostic = ConvertTo-ExitIpDiagnosticResult ([pscustomobject]@{
                ip = "203.0.113.20"
                country = "Germany"
                country_iso = "DE"
            })

        $diagnostic.ip | Should Be "203.0.113.20"
        $diagnostic.country | Should Be "DE"
        $diagnostic.openai_supported | Should Be $true
    }

    It "falls back to ifconfig.co when ipinfo.io fails" {
        Mock Invoke-RestMethod {
            throw "ipinfo unavailable"
        } -ParameterFilter { $Uri -eq "https://ipinfo.io/json" }
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                ip = "203.0.113.30"
                country = "France"
                country_iso = "FR"
            }
        } -ParameterFilter { $Uri -eq "https://ifconfig.co/json" }

        $diagnostic = Invoke-ExternalIpDiagnostic

        $diagnostic.ip | Should Be "203.0.113.30"
        $diagnostic.country | Should Be "FR"
        $diagnostic.openai_supported | Should Be $true
        Assert-MockCalled Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq "https://ipinfo.io/json" }
        Assert-MockCalled Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq "https://ifconfig.co/json" }
    }

    It "does not warn for supported OpenAI countries" {
        $lines = Format-ExitIpDiagnosticLogLines @{
            ip = "203.0.113.40"
            country = "US"
            openai_supported = $true
        }

        ($lines -join "`n") | Should Match "External IP: 203.0.113.40, country: US"
        ($lines -join "`n") | Should Not Match "VLESS exit IP is not suitable for OpenAI"
    }

    It "warns for unsupported OpenAI countries" {
        $lines = Format-ExitIpDiagnosticLogLines @{
            ip = "203.0.113.50"
            country = "RU"
            openai_supported = $false
        }

        ($lines -join "`n") | Should Match "External IP: 203.0.113.50, country: RU"
        ($lines -join "`n") | Should Match "VLESS exit IP is not suitable for OpenAI"
    }
}

Describe "Legacy route state validation" {
    It "accepts the expected previous route state shape" {
        $state = @"
{
  "default_routes": [
    {
      "destination_prefix": "0.0.0.0/0",
      "interface_index": 12,
      "next_hop": "192.168.1.1",
      "route_metric": 25
    }
  ],
  "host_routes": [
    {
      "destination_prefix": "203.0.113.10/32",
      "interface_index": 12,
      "next_hop": "192.168.1.1",
      "created": true
    }
  ]
}
"@ | ConvertFrom-Json

        $validated = ConvertTo-ValidatedLegacyRouteState $state

        $validated.default_routes[0].destination_prefix | Should Be "0.0.0.0/0"
        $validated.default_routes[0].route_metric | Should Be 25
        $validated.host_routes[0].destination_prefix | Should Be "203.0.113.10/32"
        $validated.host_routes[0].created | Should Be $true
    }

    It "rejects malformed or out-of-scope previous route state" {
        {
            ConvertTo-ValidatedLegacyRouteState @{
                default_routes = @(
                    @{
                        destination_prefix = "10.0.0.0/8"
                        interface_index = 12
                        next_hop = "192.168.1.1"
                        route_metric = 25
                    }
                )
            }
        } | Should Throw "0.0.0.0/0"

        {
            ConvertTo-ValidatedLegacyRouteState @{
                host_routes = @(
                    @{
                        destination_prefix = "203.0.113.10/24"
                        interface_index = 12
                        next_hop = "192.168.1.1"
                        created = $true
                    }
                )
            }
        } | Should Throw "IPv4 /32"

        {
            ConvertTo-ValidatedLegacyRouteState @{
                default_routes = @(
                    @{
                        destination_prefix = "0.0.0.0/0"
                        interface_index = 0
                        next_hop = "192.168.1.1"
                        route_metric = 25
                    }
                )
            }
        } | Should Throw "interface_index"
    }
}

Describe "VPN connection path regressions" {
    It "does not enable route-based kill switch during connect" {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot "vless-client.ps1"), [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0

        $startFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq "Start-VpnConnection"
        }, $true)
        $startFunction | Should Not Be $null

        $connectCommands = @($startFunction.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })

        ($connectCommands -contains "Enable-KillSwitch") | Should Be $false
        ($connectCommands -contains "Get-KillSwitchServerAddress") | Should Be $false
        ($connectCommands -contains "New-NetRoute") | Should Be $false
        ($connectCommands -contains "Remove-NetRoute") | Should Be $false
    }

    It "builds full mode without overriding the VLESS server address" {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot "vless-client.ps1"), [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0

        $startFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq "Start-VpnConnection"
        }, $true)
        $startFunction | Should Not Be $null

        $buildCommand = $startFunction.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq "Build-SingBoxConfigFromVless"
        }, $true)
        $buildCommand | Should Not Be $null
        @($buildCommand.CommandElements).Count | Should Be 4
    }

    It "schedules exit IP diagnostics only after full mode connect" {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot "vless-client.ps1"), [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0

        $startFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq "Start-VpnConnection"
        }, $true)
        $startFunction | Should Not Be $null

        $startText = $startFunction.Extent.Text
        $startText | Should Match '(?s)Set-ConnectionState\s+"Connected".*if\s*\(\$routeAllTraffic\)\s*\{.*Start-FullModeExitIpDiagnosticTimer'
        $startText | Should Not Match '(?s)else\s*\{.*Start-FullModeExitIpDiagnosticTimer'
        $startText | Should Not Match '(?s)Set-ConnectionState\s+"Connected".*Invoke-ExternalIpDiagnostic'
    }

    It "stops pending exit IP diagnostics during disconnect" {
        $scriptText = Get-Content -Path (Join-Path $repoRoot "vless-client.ps1") -Raw -Encoding UTF8

        $scriptText | Should Match '(?s)\$btnDisconnect\.Add_Click\(\{.*Stop-FullModeExitIpDiagnosticTimer.*Stop-SingBox'
    }
}

Describe "UI regressions" {
    It "keeps the log pause button and buffering path" {
        $scriptText = Get-Content -Path (Join-Path $repoRoot "vless-client.ps1") -Raw -Encoding UTF8

        $scriptText | Should Match '\$btnPauseLog\s*=\s*New-Object System\.Windows\.Forms\.Button'
        $scriptText | Should Match '\$btnPauseLog\.Text\s*=\s*"Pause"'
        $scriptText | Should Match '\$btnPauseLog\.Add_Click'
        $scriptText | Should Match '\$script:LogsPaused'
        $scriptText | Should Match 'Queue-PausedLogLine'
        $scriptText | Should Match 'Flush-PausedLogLines'
    }
}

Describe "Profile and settings ownership" {
    BeforeEach {
        Reset-TestPaths
    }

    It "reads the root settings file only as a seed and does not create runtime settings on load" {
        Write-JsonNoBom -path $script:SeedSettingsPath -value @{ vpn_domains = @("Seed.example", "*.Seed.example") } -depth 4

        $profile = Load-Profile

        ($profile.primary_domains_text -split "\r?\n|\r" -join ",") | Should Be "seed.example"
        $profile.route_all_traffic | Should Be $false
        Test-Path $script:SettingsPath | Should Be $false
    }

    It "uses runtime settings and appends updated root seed domains" {
        Write-JsonNoBom -path $script:SeedSettingsPath -value @{ vpn_domains = @("seed.example", "new-seed.example"); route_all_traffic = $true } -depth 4
        Write-JsonNoBom -path $script:SettingsPath -value @{ vpn_domains = @("runtime.example"); route_all_traffic = $false } -depth 4

        $profile = Load-Profile

        ($profile.primary_domains_text -split "\r?\n|\r" -join ",") | Should Be "runtime.example,seed.example,new-seed.example"
        $profile.route_all_traffic | Should Be $false
    }

    It "saves updated root seed domains into runtime settings without mutating the seed" {
        Write-JsonNoBom -path $script:SeedSettingsPath -value @{ vpn_domains = @("seed.example", "new-seed.example") } -depth 4
        $seedBefore = Get-Content -Path $script:SeedSettingsPath -Raw -Encoding UTF8

        Save-SettingsProfile "runtime.example`n*.Seed.example" $true

        (Get-Content -Path $script:SeedSettingsPath -Raw -Encoding UTF8) | Should Be $seedBefore
        $runtime = (Get-Content -Path $script:SettingsPath -Raw -Encoding UTF8) | ConvertFrom-Json
        (@($runtime.vpn_domains) -join ",") | Should Be "runtime.example,seed.example,new-seed.example"
        $runtime.route_all_traffic | Should Be $true
    }

    It "saves mutable settings only to runtime settings" {
        Write-JsonNoBom -path $script:SeedSettingsPath -value @{ vpn_domains = @("seed.example") } -depth 4
        $seedBefore = Get-Content -Path $script:SeedSettingsPath -Raw -Encoding UTF8

        Save-SettingsProfile "runtime.example`n*.openai.com" $true

        (Get-Content -Path $script:SeedSettingsPath -Raw -Encoding UTF8) | Should Be $seedBefore
        $runtime = (Get-Content -Path $script:SettingsPath -Raw -Encoding UTF8) | ConvertFrom-Json
        (@($runtime.vpn_domains) -contains "runtime.example") | Should Be $true
        (@($runtime.vpn_domains) -contains "*.openai.com") | Should Be $false
        $runtime.route_all_traffic | Should Be $true
    }

    It "migrates legacy profile into runtime files and removes the legacy path" {
        $legacyPath = Join-Path $script:RuntimeDir "profile.json"
        $vlessUrl = "vless://bf000d23-0752-40b4-affe-68f7707a9661@example.com:443?security=tls&type=tcp"
        Write-JsonNoBom -path $legacyPath -value @{
            vless_url = $vlessUrl
            primary_domains_text = "legacy.example`n*.legacy.example"
        } -depth 4

        $profile = Load-Profile

        $profile.vless_url | Should Be $vlessUrl
        (($profile.primary_domains_text -split "\r?\n|\r") -contains "legacy.example") | Should Be $true
        Test-Path $legacyPath | Should Be $false
        Test-Path $script:ConnectionProfilePath | Should Be $true
        Test-Path $script:SettingsPath | Should Be $true
    }
}
