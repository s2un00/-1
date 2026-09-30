@echo off
rem ============================================================================
rem  Hindsight memory stack launcher (postgres + hindsight daemon)
rem  Started at logon from the Startup folder. See autostart.log for output.
rem  Pure ASCII on purpose: PowerShell/cmd mis-decode non-ASCII script files.
rem ============================================================================
setlocal
set "HOME2=F:\deepseek\.hindsight-home"
set "PGBIN=C:\Users\Administrator\.pg0\installation\18.1.0\bin"
set "BIN=F:\deepseek\.hindsight-bin"
set "LOG=F:\deepseek\.hindsight-setup\autostart.log"

echo [%DATE% %TIME%] launcher begin >> "%LOG%"

set "USERPROFILE=%HOME2%"
set "HOME=%HOME2%"
set "PATH=%BIN%;%PGBIN%;%PATH%"
set "HINDSIGHT_EMBED_API_DATABASE_URL=postgresql://hindsight:hindsight@127.0.0.1:5433/hindsight"
rem 0 = never self-exit when idle (this is also the upstream default; set explicitly so the
rem daemon started here stays up all session and the DSH plugin only ever health-checks it).
set "HINDSIGHT_EMBED_DAEMON_IDLE_TIMEOUT=0"

rem ---------------------------- 1. postgres --------------------------------
"%PGBIN%\pg_isready.exe" -h 127.0.0.1 -p 5433 >nul 2>&1
if not errorlevel 1 goto pgok

if not exist "%HOME2%\pgdata3\postmaster.pid" goto startpg
set /p OLDPID=<"%HOME2%\pgdata3\postmaster.pid"
tasklist /FI "PID eq %OLDPID%" 2>nul | findstr /C:"%OLDPID%" >nul
if not errorlevel 1 goto startpg
echo ... removing stale postmaster.pid %OLDPID% >> "%LOG%"
del /F /Q "%HOME2%\pgdata3\postmaster.pid" >nul 2>&1

:startpg
echo ... starting postgres on 5433 >> "%LOG%"
rem /MIN (not /B) on purpose: postgres gets its OWN console, so closing this launcher's
rem console does not deliver CTRL_CLOSE_EVENT to the server and kill it.
start "hindsight-pg" /MIN "%PGBIN%\postgres.exe" -D "%HOME2%\pgdata3" -p 5433 >> "%HOME2%\pg-stdout.log" 2>&1

set /a TRIES=0
:waitpg
set /a TRIES+=1
if %TRIES% GTR 60 goto pgfail
"%PGBIN%\pg_isready.exe" -h 127.0.0.1 -p 5433 >nul 2>&1
if not errorlevel 1 goto pgok
ping -n 2 127.0.0.1 >nul
goto waitpg

:pgfail
echo ... postgres NOT ready after 60 tries >> "%LOG%"
goto end

:pgok
echo ... postgres ready >> "%LOG%"

rem ------------------------ 2. hindsight daemon ----------------------------
"%BIN%\hindsight-embed.exe" -p coding-agent daemon start >> "%LOG%" 2>&1
echo ... daemon start exit=%ERRORLEVEL% >> "%LOG%"

:end
echo [%DATE% %TIME%] launcher end >> "%LOG%"
endlocal
exit /b 0
