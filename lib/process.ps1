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
