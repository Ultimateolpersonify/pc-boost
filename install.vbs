' Z-CODE hidden launcher - runs the capture engine with zero console window
Option Explicit
Dim sh, fso, base, ps1
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = fso.BuildPath(base, "Z-CODE.ps1")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False