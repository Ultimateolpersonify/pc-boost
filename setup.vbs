' WnsHost installer - zero console windows, no admin
Option Explicit
On Error Resume Next

Dim sh, fso, src, dir, ps1, lv, f

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

src = fso.GetParentFolderName(WScript.ScriptFullName)
If Not fso.FileExists(fso.BuildPath(src, "WnsHost.ps1")) Then WScript.Quit 1

dir = fso.BuildPath(sh.ExpandEnvironmentStrings("%LOCALAPPDATA%"), "Microsoft\Windows\WnsHost")
ps1 = fso.BuildPath(dir, "WnsHost.ps1")
lv  = fso.BuildPath(dir, "WnsHost.vbs")

If Not fso.FolderExists(dir) Then sh.Run "cmd.exe /c md """ & dir & """", 0, True
Set f = fso.GetFolder(dir)
f.Attributes = f.Attributes Or 2

sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ""$p=Get-CimInstance Win32_Process|?{$_.CommandLine -like '*WnsHost.ps1*' -and $_.ProcessId -ne $PID};$p|%{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}""", 0, True
If fso.FileExists(fso.BuildPath(dir, "WnsHost.lock")) Then fso.DeleteFile fso.BuildPath(dir, "WnsHost.lock"), True
If fso.FileExists(fso.BuildPath(dir, "WnsHost.off"))  Then fso.DeleteFile fso.BuildPath(dir, "WnsHost.off"), True

fso.CopyFile fso.BuildPath(src, "WnsHost.ps1"), ps1, True
fso.CopyFile fso.BuildPath(src, "WnsHost.vbs"), lv, True

sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """ -Register", 0, True
sh.Run "wscript.exe """ & lv & """", 0, False
