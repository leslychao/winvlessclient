$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ConsoleWindow {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

. "$PSScriptRoot\lib\bootstrap.ps1"
. "$PSScriptRoot\lib\core.ps1"
. "$PSScriptRoot\lib\process.ps1"

if (-not (Enter-SingleInstance)) {
    [System.Windows.Forms.MessageBox]::Show("VLESS Client is already running.", "VLESS Client", "OK", "Information") | Out-Null
    exit 0
}

try {
    $h = [ConsoleWindow]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) {
        [ConsoleWindow]::ShowWindow($h, 0) | Out-Null
    }
} catch {}

function Release-AppResources {
    try {
        if ($script:HealthTimer) { $script:HealthTimer.Stop() }
    } catch {}
    try {
        Stop-SingBox
    } catch {}
    try {
        if ($script:TrayIcon) {
            $script:TrayIcon.Visible = $false
            $script:TrayIcon.Dispose()
        }
    } catch {}
    try {
        if ($script:JobHandle -ne [IntPtr]::Zero) {
            [JobObjectApi]::CloseHandle($script:JobHandle) | Out-Null
            $script:JobHandle = [IntPtr]::Zero
        }
    } catch {}
    try {
        Release-SingleInstance
    } catch {}
}

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
        Release-AppResources
    }
)
[System.AppDomain]::CurrentDomain.add_ProcessExit([System.EventHandler]{ param($sender, $eventArgs) Release-AppResources })

# UI
$form = New-Object System.Windows.Forms.Form
$form.Text = "winvlessclient $script:AppVersion"
$form.Size = New-Object System.Drawing.Size(900, 700)
$form.MinimumSize = New-Object System.Drawing.Size(600, 500)
$form.StartPosition = "CenterScreen"

# Tray icon
$script:TrayExiting = $false
$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
try {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:TrayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
} catch {
    $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$script:TrayIcon.Text = "VLESS Client $script:AppVersion"
$script:TrayIcon.Visible = $false

function Restore-FromTray {
    $script:TrayIcon.Visible = $false
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add("Show", $null, { Restore-FromTray })
[void]$trayMenu.Items.Add("-")
[void]$trayMenu.Items.Add("Exit", $null, {
    $script:TrayExiting = $true
    $form.Close()
})
$script:TrayIcon.ContextMenuStrip = $trayMenu
$script:TrayIcon.Add_DoubleClick({ Restore-FromTray })

$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.Hide()
        $script:TrayIcon.Visible = $true
    }
})

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

$labelDomains = New-Object System.Windows.Forms.Label
$labelDomains.Text = "Primary domains via VPN (one per line):"
$labelDomains.Location = New-Object System.Drawing.Point(16, 76)
$labelDomains.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($labelDomains)

$txtDomains = New-Object System.Windows.Forms.TextBox
$txtDomains.Multiline = $true
$txtDomains.ScrollBars = "Vertical"
$txtDomains.Location = New-Object System.Drawing.Point(16, 100)
$txtDomains.Size = New-Object System.Drawing.Size(850, 150)
$txtDomains.Anchor = "Top,Left,Right"
$txtDomains.ShortcutsEnabled = $true
$txtDomains.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::A) {
        $txtDomains.SelectAll()
        $_.SuppressKeyPress = $true
    }
})
$form.Controls.Add($txtDomains)

$splitter = New-Object System.Windows.Forms.Panel
$splitter.Location = New-Object System.Drawing.Point(16, 254)
$splitter.Size = New-Object System.Drawing.Size(850, 6)
$splitter.Cursor = [System.Windows.Forms.Cursors]::HSplit
$splitter.BackColor = [System.Drawing.SystemColors]::ControlDark
$splitter.Anchor = "Top,Left,Right"
$form.Controls.Add($splitter)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Connect"
$btnConnect.Location = New-Object System.Drawing.Point(16, 270)
$btnConnect.Size = New-Object System.Drawing.Size(120, 36)
$form.Controls.Add($btnConnect)

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "Disconnect"
$btnDisconnect.Location = New-Object System.Drawing.Point(148, 270)
$btnDisconnect.Size = New-Object System.Drawing.Size(120, 36)
$btnDisconnect.Enabled = $false
$form.Controls.Add($btnDisconnect)

$chkRouteAllTraffic = New-Object System.Windows.Forms.CheckBox
$chkRouteAllTraffic.Text = "Route all traffic through VPN"
$chkRouteAllTraffic.Location = New-Object System.Drawing.Point(290, 276)
$chkRouteAllTraffic.Size = New-Object System.Drawing.Size(220, 24)
$chkRouteAllTraffic.Anchor = "Top,Left"
$form.Controls.Add($chkRouteAllTraffic)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Status: Disconnected (Selective VPN mode)"
$lblStatus.Location = New-Object System.Drawing.Point(16, 316)
$lblStatus.Size = New-Object System.Drawing.Size(850, 24)
$lblStatus.Anchor = "Top,Left,Right"
$form.Controls.Add($lblStatus)

$btnCopyLog = New-Object System.Windows.Forms.Button
$btnCopyLog.Text = "Copy"
$btnCopyLog.Location = New-Object System.Drawing.Point(760, 346)
$btnCopyLog.Size = New-Object System.Drawing.Size(50, 26)
$btnCopyLog.Anchor = "Top,Right"
$form.Controls.Add($btnCopyLog)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = "Clear"
$btnClearLog.Location = New-Object System.Drawing.Point(816, 346)
$btnClearLog.Size = New-Object System.Drawing.Size(50, 26)
$btnClearLog.Anchor = "Top,Right"
$form.Controls.Add($btnClearLog)

$txtLogs = New-Object System.Windows.Forms.TextBox
$txtLogs.Multiline = $true
$txtLogs.ScrollBars = "Vertical"
$txtLogs.ReadOnly = $true
$txtLogs.ShortcutsEnabled = $true
$txtLogs.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::A) {
        $txtLogs.SelectAll()
        $_.SuppressKeyPress = $true
    }
})
$txtLogs.Location = New-Object System.Drawing.Point(16, 376)
$txtLogs.Size = New-Object System.Drawing.Size(850, 274)
$txtLogs.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($txtLogs)

# Draggable splitter between domains and logs
$script:SplitDragging = $false
$script:SplitStartY = 0
$script:SplitStartTop = 0

$splitter.Add_MouseDown({
    $script:SplitDragging = $true
    $script:SplitStartY = [System.Windows.Forms.Cursor]::Position.Y
    $script:SplitStartTop = $splitter.Top
    $splitter.Capture = $true
})

$splitter.Add_MouseMove({
    if (-not $script:SplitDragging) { return }
    $delta = [System.Windows.Forms.Cursor]::Position.Y - $script:SplitStartY
    $newTop = $script:SplitStartTop + $delta
    $minTop = $txtDomains.Top + 60
    $maxTop = $txtLogs.Bottom - 80
    $newTop = [Math]::Max($minTop, [Math]::Min($maxTop, $newTop))
    $shift = $newTop - $splitter.Top
    if ($shift -eq 0) { return }
    $form.SuspendLayout()
    $txtDomains.Height += $shift
    $splitter.Top += $shift
    $btnConnect.Top += $shift
    $btnDisconnect.Top += $shift
    $chkRouteAllTraffic.Top += $shift
    $lblStatus.Top += $shift
    $btnCopyLog.Top += $shift
    $btnClearLog.Top += $shift
    $txtLogs.Top += $shift
    $txtLogs.Height -= $shift
    $form.ResumeLayout($true)
})

$splitter.Add_MouseUp({
    $script:SplitDragging = $false
    $splitter.Capture = $false
})

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

function Get-RouteModeLabel {
    if ($chkRouteAllTraffic -and $chkRouteAllTraffic.Checked) { return "Full VPN mode" }
    return "Selective VPN mode"
}

function Test-SingBoxRunning {
    return ($script:ProcessRef -and -not $script:ProcessRef.HasExited)
}

function Set-ConnectionState([string]$state) {
    $routeMode = Get-RouteModeLabel
    switch ($state) {
        "Connecting" {
            $btnConnect.Enabled = $false
            $btnDisconnect.Enabled = $false
            $chkRouteAllTraffic.Enabled = $false
            $lblStatus.Text = "Status: Connecting ($routeMode)"
        }
        "Connected" {
            $btnConnect.Enabled = $false
            $btnDisconnect.Enabled = $true
            $chkRouteAllTraffic.Enabled = $true
            $lblStatus.Text = "Status: Connected ($routeMode)"
        }
        "Error" {
            $btnConnect.Enabled = $true
            $btnDisconnect.Enabled = $false
            $chkRouteAllTraffic.Enabled = $true
            $lblStatus.Text = "Status: Error ($routeMode)"
        }
        default {
            $btnConnect.Enabled = $true
            $btnDisconnect.Enabled = $false
            $chkRouteAllTraffic.Enabled = $true
            $lblStatus.Text = "Status: Disconnected ($routeMode)"
        }
    }
}

$btnCopyLog.Add_Click({
    if ($txtLogs.TextLength -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText($txtLogs.Text)
    }
})

$btnClearLog.Add_Click({
    $txtLogs.Clear()
})

$script:HealthTimer = New-Object System.Windows.Forms.Timer
$script:HealthTimer.Interval = 1000
$script:HealthTimer.Add_Tick({
    try {
        Read-SingBoxLogDelta
        if ($script:ProcessRef -and $script:ProcessRef.HasExited) {
            $exitCode = $script:ProcessRef.ExitCode
            $script:HealthTimer.Stop()
            $script:ProcessRef = $null
            Set-ConnectionState "Disconnected"
            Append-Log ("sing-box exited with code: " + $exitCode)
        }
    } catch {
        Append-FileLog ("Health timer error: " + $_.Exception.Message)
    }
})

$profile = Load-Profile
$txtVless.Text = $profile.vless_url
if ([string]::IsNullOrWhiteSpace([string]$profile.primary_domains_text)) {
    $txtDomains.Text = (Get-DefaultVpnDomains) -join [Environment]::NewLine
} else {
    $txtDomains.Text = [string]$profile.primary_domains_text
}
$script:RouteModeUpdating = $true
try {
    $chkRouteAllTraffic.Checked = [bool]$profile.route_all_traffic
} finally {
    $script:RouteModeUpdating = $false
}
Set-ConnectionState "Disconnected"
Ensure-JobObject

$form.Add_Shown({
    try {
        $killed = Stop-OrphanSingBox $profile.singbox_path
        if ($killed -gt 0) {
            Append-Log ("Stopped old sing-box processes: " + $killed)
        }
    } catch {
        Append-FileLog ("Startup cleanup error: " + $_.Exception.Message)
    }
})

function Start-VpnConnection {
    try {
        Set-ConnectionState "Connecting"
        $singboxPath = [string]$profile.singbox_path
        if (-not (Test-Path $singboxPath)) { throw "sing-box.exe not found: $singboxPath" }
        if (-not (Test-IsAdmin)) { throw "VPN mode (TUN) requires Administrator rights. Restart start.cmd as Administrator." }

        if (Test-SingBoxRunning) {
            if ($script:HealthTimer) { $script:HealthTimer.Stop() }
            Stop-SingBox
            Append-Log "Stopped previous connection."
        }

        $killedBeforeConnect = Stop-OrphanSingBox $singboxPath
        if ($killedBeforeConnect -gt 0) {
            Append-Log ("Stopped orphan sing-box processes: " + $killedBeforeConnect)
        }

        $vlessUrl = $txtVless.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($vlessUrl)) { throw "VLESS URL is empty" }

        $vpnDomains = Merge-RequiredVpnDomains (Get-NormalizedDomainList $txtDomains.Text)
        $routeAllTraffic = [bool]$chkRouteAllTraffic.Checked
        if (-not $routeAllTraffic -and (-not $vpnDomains -or $vpnDomains.Count -eq 0)) {
            throw "Primary domain list is empty. Add at least one domain."
        }

        $config = Build-SingBoxConfigFromVless $vlessUrl $vpnDomains $routeAllTraffic
        Write-TextNoBom -path $script:ConfigPath -content ($config | ConvertTo-Json -Depth 20)
        Assert-SingBoxConfigValid $singboxPath $script:ConfigPath | Out-Null
        if (Test-Path $script:SingBoxLogPath) {
            Remove-Item -Path $script:SingBoxLogPath -Force -ErrorAction SilentlyContinue
        }
        $script:LastSingBoxLogOffset = 0

        Save-Profile @{
            vless_url = $vlessUrl
            primary_domains_text = ($vpnDomains -join [Environment]::NewLine)
            route_all_traffic = $routeAllTraffic
        }
        $profile["vless_url"] = $vlessUrl
        $profile["primary_domains_text"] = ($vpnDomains -join [Environment]::NewLine)
        $profile["route_all_traffic"] = $routeAllTraffic

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
        Set-ConnectionState "Connected"
        if ($routeAllTraffic) {
            Append-Log ("Connected. PID=" + $proc.Id + ", TUN=sb-vpn, mode=full")
        } else {
            Append-Log ("Connected. PID=" + $proc.Id + ", TUN=sb-vpn, mode=selective, domains=" + $vpnDomains.Count)
        }
    } catch {
        if ($script:HealthTimer) { $script:HealthTimer.Stop() }
        Stop-SingBox
        Set-ConnectionState "Error"
        Append-Log ("ERROR: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Connection error", "OK", "Error") | Out-Null
    }
}

$btnConnect.Add_Click({
    Start-VpnConnection
})

$chkRouteAllTraffic.Add_CheckedChanged({
    if ($script:RouteModeUpdating) { return }
    $routeAllTraffic = [bool]$chkRouteAllTraffic.Checked
    try {
        $vpnDomains = Merge-RequiredVpnDomains (Get-NormalizedDomainList $txtDomains.Text)
        Save-Profile @{
            vless_url = $txtVless.Text.Trim()
            primary_domains_text = ($vpnDomains -join [Environment]::NewLine)
            route_all_traffic = $routeAllTraffic
        }
        $profile["vless_url"] = $txtVless.Text.Trim()
        $profile["primary_domains_text"] = ($vpnDomains -join [Environment]::NewLine)
        $profile["route_all_traffic"] = $routeAllTraffic
        if (Test-SingBoxRunning) {
            Append-Log ("Routing mode changed to " + (Get-RouteModeLabel) + ". Reconnecting.")
            Start-VpnConnection
        } else {
            Set-ConnectionState "Disconnected"
            Append-Log ("Routing mode saved: " + (Get-RouteModeLabel))
        }
    } catch {
        $script:RouteModeUpdating = $true
        try {
            $chkRouteAllTraffic.Checked = -not $routeAllTraffic
        } finally {
            $script:RouteModeUpdating = $false
        }
        if (Test-SingBoxRunning) {
            Set-ConnectionState "Connected"
        } else {
            Set-ConnectionState "Disconnected"
        }
        Append-Log ("ERROR: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Routing mode error", "OK", "Error") | Out-Null
    }
})

$btnDisconnect.Add_Click({
    if ($script:HealthTimer) { $script:HealthTimer.Stop() }
    Stop-SingBox
    Set-ConnectionState "Disconnected"
    Append-Log "Disconnected."
})

$form.Add_FormClosing({
    $evtArgs = $_
    if (-not $script:TrayExiting) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Are you sure you want to exit?`nVPN connection will be stopped.",
            "Exit VLESS Client",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $evtArgs.Cancel = $true
            return
        }
    }
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    Release-AppResources
})

[System.Windows.Forms.Application]::Run($form)
