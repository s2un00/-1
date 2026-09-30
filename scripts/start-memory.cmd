@echo off
rem ============================================================================
rem  Double-click this file to start the Hindsight memory stack by hand.
rem
rem  It does not do any work itself: it calls the canonical launcher
rem  (F:\deepseek\.hindsight-setup\start-memory-stack.cmd, the same one the
rem  Startup folder runs at logon) and then reports what ended up listening.
rem
rem  Pure ASCII on purpose: cmd mis-decodes non-ASCII script files.
rem ============================================================================
echo Starting the Hindsight memory stack (postgres + daemon).
echo This takes about 30 seconds. Please wait...
echo.

call "F:\deepseek\.hindsight-setup\start-memory-stack.cmd"

echo.
echo ---- what is listening now ----
netstat -ano | findstr /C:"LISTENING" | findstr /C:":5433 " /C:":9077 "
echo.
echo   5433 = PostgreSQL        (where the memories are stored)
echo   9077 = Hindsight daemon  (the memory API the DSH plugin talks to)
echo.
echo If both lines above show a listener, memory is up.
echo Full log: F:\deepseek\.hindsight-setup\autostart.log
echo.
pause
