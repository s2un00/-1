' Hindsight memory stack - hidden launcher.
' Lives in the Startup folder and runs start-memory-stack.cmd with no window.
' Also used on demand:  wscript.exe "F:\deepseek\.hindsight-setup\start-memory-stack.vbs"
Set sh = CreateObject("WScript.Shell")
sh.Run "cmd /c F:\deepseek\.hindsight-setup\start-memory-stack.cmd", 0, False
