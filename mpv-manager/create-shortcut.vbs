Set shell = WScript.CreateObject("WScript.Shell")
Set shortcut = shell.CreateShortcut(WScript.Arguments(0))
shortcut.TargetPath = WScript.Arguments(1)
shortcut.WorkingDirectory = WScript.Arguments(2)
shortcut.Description = WScript.Arguments(3)
shortcut.IconLocation = WScript.Arguments(4)
shortcut.Save
