' Hidden UAC relaunch. No console of its own.
If WScript.Arguments.Count < 1 Then WScript.Quit 1
bat = WScript.Arguments(0)
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(bat)
Set sh = CreateObject("Shell.Application")
sh.ShellExecute bat, "__run", dir, "runas", 1
