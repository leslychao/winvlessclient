$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. "$PSScriptRoot\lib\bootstrap.ps1"
. "$PSScriptRoot\lib\core.ps1"
. "$PSScriptRoot\lib\process.ps1"

# Keep app alive on UI/runtime exceptions.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException(
    [System.Threading.ThreadExceptionEventHandler]{
        param($sender, $eventArgs)
        $msg = "Unhandled UI exception: " + $eventArgs.Exception.Message
        Append-FileLog $msg
        [System.Windows.Forms.MessageBox]::Show($msg, "VLESS client error", "OK", "Error") | Out-Null
    }
)
[System.AppDomain]::CurrentDomain.add_UnhandledException(
    [System.UnhandledExceptionEventHandler]{
        param($sender, $eventArgs)
        $ex = $eventArgs.ExceptionObject
        if ($ex -is [Exception]) {
            Append-FileLog ("Unhandled domain exception: " + $ex.ToString())
        } else {
            Append-FileLog "Unhandled domain exception: unknown object"
        }
    }
)

# UI
$form = New-Object System.Windows.Forms.Form
$form.Text = "winvlessclient"
$form.Size = New-Object System.Drawing.Size(900, 620)
$form.StartPosition = "CenterScreen"

$labelVless = New-Object System.Windows.Forms.Label
$labelVless.Text = "VLESS URL:"
$labelVless.Location = New-Object System.Drawing.Point(16, 16)
$labelVless.Size = New-Object System.Drawing.Size(120, 20)
$form.Controls.Add($labelVless)

$txtVless = New-Object System.Windows.Forms.TextBox
$txtVless.Location = New-Object System.Drawing.Point(16, 40)
$txtVless.Size = New-Object System.Drawing.Size(850, 28)
$txtVless.Anchor = "Top,Left,Right"
$form.Controls.Add($txtVless)

$labelPath = New-Object System.Windows.Forms.Label
$labelPath.Text = "Path to sing-box.exe:"
$labelPath.Location = New-Object System.Drawing.Point(16, 76)
$labelPath.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($labelPath)

$txtPath = New-Object System.Windows.Forms.TextBox
$txtPath.Location = New-Object System.Drawing.Point(16, 100)
$txtPath.Size = New-Object System.Drawing.Size(850, 28)
$txtPath.Anchor = "Top,Left,Right"
$form.Controls.Add($txtPath)

$labelDomains = New-Object System.Windows.Forms.Label
$labelDomains.Text = "Primary domains via VPN (one per line):"
$labelDomains.Location = New-Object System.Drawing.Point(16, 136)
$labelDomains.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($labelDomains)

$txtDomains = New-Object System.Windows.Forms.TextBox
$txtDomains.Multiline = $true
$txtDomains.ScrollBars = "Vertical"
$txtDomains.Location = New-Object System.Drawing.Point(16, 160)
$txtDomains.Size = New-Object System.Drawing.Size(850, 90)
$txtDomains.Anchor = "Top,Left,Right"
$form.Controls.Add($txtDomains)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Connect"
$btnConnect.Location = New-Object System.Drawing.Point(16, 262)
$btnConnect.Size = New-Object System.Drawing.Size(120, 36)
$form.Controls.Add($btnConnect)

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "Disconnect"
$btnDisconnect.Location = New-Object System.Drawing.Point(148, 262)
$btnDisconnect.Size = New-Object System.Drawing.Size(120, 36)
$btnDisconnect.Enabled = $false
$form.Controls.Add($btnDisconnect)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Status: Disconnected (Selective VPN mode)"
$lblStatus.Location = New-Object System.Drawing.Point(290, 270)
$lblStatus.Size = New-Object System.Drawing.Size(560, 24)
$lblStatus.Anchor = "Top,Left,Right"
$form.Controls.Add($lblStatus)

$txtLogs = New-Object System.Windows.Forms.TextBox
$txtLogs.Multiline = $true
$txtLogs.ScrollBars = "Vertical"
$txtLogs.ReadOnly = $true
$txtLogs.Location = New-Object System.Drawing.Point(16, 312)
$txtLogs.Size = New-Object System.Drawing.Size(850, 258)
$txtLogs.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($txtLogs)

function Append-Log([string]$message) {
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $message
        if ($txtLogs.TextLength -gt 200000) {
            $txtLogs.Text = $txtLogs.Text.Substring($txtLogs.TextLength - 100000)
        }
        $txtLogs.AppendText($line + [Environment]::NewLine)
    } catch {}
    Append-FileLog $message
}

$script:HealthTimer = New-Object System.Windows.Forms.Timer
$script:HealthTimer.Interval = 1000
$script:HealthTimer.Add_Tick({
    try {
        Read-SingBoxLogDelta
        if ($script:ProcessRef -and $script:ProcessRef.HasExited) {
            $exitCode = $script:ProcessRef.ExitCode
            $script:HealthTimer.Stop()
            $script:ProcessRef = $null
            $btnConnect.Enabled = $true
            $btnDisconnect.Enabled = $false
            $lblStatus.Text = "Status: Disconnected (Selective VPN mode)"
            Append-Log ("sing-box exited with code: " + $exitCode)
        }
    } catch {
        Append-FileLog ("Health timer error: " + $_.Exception.Message)
    }
})

$profile = Load-Profile
$txtPath.Text = $profile.singbox_path
$txtVless.Text = $profile.vless_url
if ([string]::IsNullOrWhiteSpace([string]$profile.primary_domains_text)) {
    $txtDomains.Text = (Get-DefaultVpnDomains) -join [Environment]::NewLine
} else {
    $txtDomains.Text = [string]$profile.primary_domains_text
}
Ensure-JobObject

$form.Add_Shown({
    try {
        $startupPath = $txtPath.Text.Trim()
        $killed = Stop-OrphanSingBox $startupPath
        if ($killed -gt 0) {
            Append-Log ("Stopped old sing-box processes: " + $killed)
        }
    } catch {
        Append-FileLog ("Startup cleanup error: " + $_.Exception.Message)
    }
})

$btnConnect.Add_Click({
    try {
        if ($script:ProcessRef -and -not $script:ProcessRef.HasExited) {
            Append-Log "Already connected."
            return
        }

        $singboxPath = $txtPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($singboxPath)) { throw "Specify path to sing-box.exe" }
        if (-not (Test-Path $singboxPath)) { throw "sing-box.exe not found: $singboxPath" }
        if (-not (Test-IsAdmin)) { throw "Selective VPN mode (TUN) requires Administrator rights. Restart start.cmd as Administrator." }

        $killedBeforeConnect = Stop-OrphanSingBox $singboxPath
        if ($killedBeforeConnect -gt 0) {
            Append-Log ("Stopped old sing-box before connect: " + $killedBeforeConnect)
        }

        $vlessUrl = $txtVless.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($vlessUrl)) { throw "VLESS URL is empty" }

        $userDomains = Get-NormalizedDomainList $txtDomains.Text
        $vpnDomains = Expand-VpnDomainGroups $userDomains
        if (-not $vpnDomains -or $vpnDomains.Count -eq 0) { throw "Primary domain list is empty. Add at least one domain." }
        if ($vpnDomains.Count -gt $userDomains.Count) {
            Append-Log ("Auto-expanded domains: " + $userDomains.Count + " -> " + $vpnDomains.Count)
        }

        $config = Build-SingBoxConfigFromVless $vlessUrl $vpnDomains
        Write-TextNoBom -path $script:ConfigPath -content ($config | ConvertTo-Json -Depth 20)
        if (Test-Path $script:SingBoxLogPath) {
            Remove-Item -Path $script:SingBoxLogPath -Force -ErrorAction SilentlyContinue
        }
        $script:LastSingBoxLogLineCount = 0

        Save-Profile @{
            singbox_path = $singboxPath
            vless_url = $vlessUrl
            primary_domains_text = ($userDomains -join [Environment]::NewLine)
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $singboxPath
        $psi.Arguments = ('run -c "{0}"' -f $script:ConfigPath)
        $psi.WorkingDirectory = $script:AppRoot
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) { throw "Failed to start sing-box process" }
        Add-ProcessToJob $proc
        $script:ProcessRef = $proc

        $script:HealthTimer.Start()
        $btnConnect.Enabled = $false
        $btnDisconnect.Enabled = $true
        $lblStatus.Text = "Status: Connected (Selective VPN mode)"
        Append-Log ("Connected. PID=" + $proc.Id + ", TUN=sb-vpn, domains=" + $vpnDomains.Count)
    } catch {
        if ($script:HealthTimer) { $script:HealthTimer.Stop() }
        Stop-SingBox
        $btnConnect.Enabled = $true
        $btnDisconnect.Enabled = $false
        $lblStatus.Text = "Status: Error (Selective VPN mode)"
        Append-Log ("ERROR: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Connection error", "OK", "Error") | Out-Null
    }
})

$btnDisconnect.Add_Click({
    if ($script:HealthTimer) { $script:HealthTimer.Stop() }
    Stop-SingBox
    $btnConnect.Enabled = $true
    $btnDisconnect.Enabled = $false
    $lblStatus.Text = "Status: Disconnected (Selective VPN mode)"
    Append-Log "Disconnected."
})

$form.Add_FormClosing({
    if ($script:HealthTimer) { $script:HealthTimer.Stop() }
    Stop-SingBox
    if ($script:JobHandle -ne [IntPtr]::Zero) {
        [JobObjectApi]::CloseHandle($script:JobHandle) | Out-Null
        $script:JobHandle = [IntPtr]::Zero
    }
})

[void]$form.ShowDialog()
