function Ensure-JobObject {
    if ($script:JobHandle -ne [IntPtr]::Zero) { return }
    try {
        $script:JobHandle = [JobObjectApi]::CreateKillOnCloseJob()
    } catch {
        Append-FileLog ("Job object init failed: " + $_.Exception.Message)
        $script:JobHandle = [IntPtr]::Zero
    }
}

function Add-ProcessToJob([System.Diagnostics.Process]$proc) {
    if (-not $proc) { return }
    if ($script:JobHandle -eq [IntPtr]::Zero) { return }
    try {
        $ok = [JobObjectApi]::AssignProcessToJobObject($script:JobHandle, $proc.Handle)
        if (-not $ok) {
            Append-FileLog ("AssignProcessToJobObject failed for PID " + $proc.Id)
        }
    } catch {
        Append-FileLog ("Assign process to job error: " + $_.Exception.Message)
    }
}

function Enter-SingleInstance {
    if ($script:InstanceMutex) { return $true }

    $createdNew = $false
    try {
        $mutex = New-Object System.Threading.Mutex($true, $script:InstanceMutexName, [ref]$createdNew)
        if (-not $createdNew) {
            $mutex.Dispose()
            return $false
        }
        $script:InstanceMutex = $mutex
        return $true
    } catch {
        Append-FileLog ("Single-instance guard failed: " + $_.Exception.Message)
        throw
    }
}

function Release-SingleInstance {
    if (-not $script:InstanceMutex) { return }
    try {
        $script:InstanceMutex.ReleaseMutex() | Out-Null
    } catch {}
    try {
        $script:InstanceMutex.Dispose()
    } catch {}
    $script:InstanceMutex = $null
}
