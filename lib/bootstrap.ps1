$script:AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:RuntimeDir = Join-Path $script:AppRoot "runtime"
$script:ConnectionProfilePath = Join-Path $script:RuntimeDir "connection.private.json"
$script:SettingsPath = Join-Path $script:AppRoot "settings.json"
$script:ConfigPath = Join-Path $script:RuntimeDir "config.json"
$script:ClientLogPath = Join-Path $script:RuntimeDir "client.log"
$script:SingBoxLogPath = Join-Path $script:RuntimeDir "sing-box.log"

if (-not (Test-Path $script:RuntimeDir)) {
    New-Item -Path $script:RuntimeDir -ItemType Directory | Out-Null
}

$script:ProcessRef = $null
$script:HealthTimer = $null
$script:JobHandle = [IntPtr]::Zero
$script:LastSingBoxLogOffset = 0
$script:ClientLogMaxBytes = 1MB
$script:SingBoxLogMaxBytes = 5MB
$script:LogBackupCount = 3

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class JobObjectApi {
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public static IntPtr CreateKillOnCloseJob() {
        IntPtr hJob = CreateJobObject(IntPtr.Zero, null);
        if (hJob == IntPtr.Zero) {
            throw new InvalidOperationException("CreateJobObject failed.");
        }

        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr pInfo = Marshal.AllocHGlobal(length);
        try {
            Marshal.StructureToPtr(info, pInfo, false);
            if (!SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, pInfo, (uint)length)) {
                throw new InvalidOperationException("SetInformationJobObject failed.");
            }
        } finally {
            Marshal.FreeHGlobal(pInfo);
        }
        return hJob;
    }
}
"@
