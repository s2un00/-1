$ErrorActionPreference = 'Continue'
# keep-stack3.ps1 -- hold Postgres(5433) + hindsight daemon(9077) alive.
# Launch it as a background job that never exits: the job is the parent that
# keeps the whole process tree from being reaped.
#
# Why .NET Process instead of Start-Process:
#   the inherited environment contains duplicate keys that differ only in case
#   (http_proxy / HTTP_PROXY, Path / PATH). Start-Process rebuilds a
#   *case-sensitive* dictionary from them and throws
#   "dict already contains key 'http_proxy', adding 'HTTP_PROXY'".
#   We therefore (a) strip proxy vars from this process and (b) hand the child
#   an explicitly built, single-cased environment.

$log = 'F:\deepseek\.hindsight-setup\keep-stack3.log'
function Say($m) {
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m
    Write-Output $line
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 } catch { }
}

$bin    = 'F:\deepseek\.hindsight-bin'
$home2  = 'F:\deepseek\.hindsight-home'
$pgBin  = 'C:\Users\Administrator\.pg0\installation\18.1.0\bin'
$pgData = Join-Path $home2 'pgdata3'
$dbUrl  = 'postgresql://hindsight:hindsight@127.0.0.1:5433/hindsight'
$apiPort = '9077'

# --- 0. no proxy for localhost, and no duplicate-cased proxy vars ---------
foreach ($n in 'http_proxy','https_proxy','all_proxy','no_proxy') {
    [Environment]::SetEnvironmentVariable($n, $null, 'Process')
}
[System.Net.WebRequest]::DefaultWebProxy = $null

# --- environment the daemon needs -----------------------------------------
$env:HINDSIGHT_SERVER_MODE          = 'daemon'
$env:HINDSIGHT_DAEMON_PROFILE       = 'coding-agent'
$env:HINDSIGHT_API_PORT             = $apiPort
$env:HINDSIGHT_EMBED_VERSION        = '0.10.2'
$env:HINDSIGHT_API_DATABASE_URL     = $dbUrl
$env:HINDSIGHT_API_DATABASE_URL_RAW = $dbUrl
$env:HINDSIGHT_API_LLM_PROVIDER     = 'deepseek'
$env:HINDSIGHT_API_LLM_MODEL        = 'deepseek-chat'
$env:HINDSIGHT_API_LLM_BASE_URL     = 'https://api.deepseek.com'
$env:HINDSIGHT_API_EMBEDDINGS_PROVIDER = 'onnx'
$env:HINDSIGHT_API_EMBEDDINGS_ONNX_MODEL_PATH = Join-Path $home2 'models\bge-small-en-v1.5\onnx\model.onnx'
$env:HINDSIGHT_API_EMBEDDINGS_ONNX_TOKENIZER_NAME_OR_PATH = Join-Path $home2 'models\bge-small-en-v1.5'
$env:HINDSIGHT_API_RERANKER_PROVIDER = 'flashrank'
$env:HINDSIGHT_API_RERANKER_FLASHRANK_MODEL = 'ms-marco-MultiBERT-L-12'
$env:HINDSIGHT_API_RERANKER_FLASHRANK_CACHE_DIR = Join-Path $home2 'flashrank-cache'
$env:HINDSIGHT_API_PG0_DATA_DIR     = Join-Path $home2 'AppData\Local\pg0'
$env:USERPROFILE                    = $home2
$env:HOME                           = $home2
$env:HF_ENDPOINT                    = 'https://hf-mirror.com'
$env:HF_HOME                        = Join-Path $home2 '.cache\huggingface'
$env:HF_HUB_OFFLINE                 = '1'
$env:HF_HUB_DISABLE_SYMLINKS        = '1'
$env:UV_TOOL_DIR                    = 'F:\deepseek\.hindsight-setup\uv-tools'
$env:UV_PYTHON_INSTALL_DIR          = 'F:\deepseek\.hindsight-setup\uv-python'
$env:UV_CACHE_DIR                   = 'F:\deepseek\.hindsight-setup\uv-cache'
$env:UV_LINK_MODE                   = 'copy'
$env:UV_TOOL_BIN_DIR                = $bin
$env:TEMP                           = 'C:\Users\Administrator\AppData\Local\Temp'
$env:TMP                            = 'C:\Users\Administrator\AppData\Local\Temp'

function Test-PgUp {
    $probe = & (Join-Path $pgBin 'pg_isready.exe') -h 127.0.0.1 -p 5433 2>&1
    return ($probe -match 'accepting connections')
}

function Start-Pg {
    $pidFile = Join-Path $pgData 'postmaster.pid'
    if (Test-Path $pidFile) {
        $stalePid = (Get-Content $pidFile -First 1).Trim()
        if (-not (Get-Process -Id $stalePid -ErrorAction SilentlyContinue)) {
            Say ('removing stale postmaster.pid for dead pid ' + $stalePid)
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        }
    }
    Say 'starting postgres.exe on 5433'
    $out = Join-Path $home2 'pg-stdout.log'
    $err = Join-Path $home2 'pg-stderr.log'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = Join-Path $pgBin 'postgres.exe'
    $psi.Arguments = '-D "' + $pgData + '" -p 5433'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    # hand the child a clean, single-cased environment
    $psi.EnvironmentVariables.Clear()
    foreach ($k in 'SystemRoot','windir','SystemDrive','ComSpec','PATHEXT','OS',
                   'NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE','PROCESSOR_IDENTIFIER',
                   'TEMP','TMP','USERPROFILE','HOME','APPDATA','LOCALAPPDATA','ProgramData','Path') {
        $v = [Environment]::GetEnvironmentVariable($k, 'Process')
        if ($v) { $psi.EnvironmentVariables[$k] = $v }
    }
    $psi.EnvironmentVariables['Path'] = $bin + ';' + $pgBin + ';' + [Environment]::GetEnvironmentVariable('Path', 'Process')

    $proc = [System.Diagnostics.Process]::Start($psi)
    # drain both pipes to files so postgres can never block on a full pipe
    $script:pgOut = [IO.File]::Open($out, 'Append', 'Write', 'Read')
    $script:pgErr = [IO.File]::Open($err, 'Append', 'Write', 'Read')
    $script:pgOutTask = $proc.StandardOutput.BaseStream.CopyToAsync($script:pgOut)
    $script:pgErrTask = $proc.StandardError.BaseStream.CopyToAsync($script:pgErr)
    Say ('postgres pid = ' + $proc.Id + ' (logs: pg-stdout.log / pg-stderr.log)')
    return $proc
}

function Test-Health {
    # Returns 'healthy' ONLY when /health reports a healthy database.
    #
    # Why not "non-empty response means up": a daemon whose Postgres has died still
    # answers HTTP 200, with {"status":"unhealthy","database":"error",...}. Treating
    # that as up means the supervise loop never restarts anything -- observed
    # 2026-09-30 17:41: daemon 11460 alive, 5433 gone, log said "daemon already
    # healthy". The daemon happened to reconnect on its own; if it had not, the
    # supervisor would have sat there doing nothing.
    try {
        $r = Invoke-WebRequest ('http://127.0.0.1:' + $apiPort + '/health') -UseBasicParsing -TimeoutSec 5
        if ($r.Content -match '"status"\s*:\s*"healthy"') { return 'healthy' }
        return ''
    } catch { return '' }
}

# Spawn a process so that it is NOT a member of the caller's Windows job object.
#
# Why this is the only way out
#   A background job is torn down by killing every process in its job object.
#   `detached` / DETACHED_PROCESS only detach the console, not the job, so an
#   ordinary child dies with us however it is launched.  The one documented
#   escape -- CREATE_BREAKAWAY_FROM_JOB -- is refused with WinError 5 here,
#   because the harness job does not set JOB_OBJECT_LIMIT_BREAKAWAY_OK.
#   The WMI provider, however, runs inside a *service* process (WmiPrvSE.exe)
#   that is not in our job, so a process it creates is not a job member either
#   and is never reaped by our teardown.
#
# Trade-off: WMI children do NOT inherit this process's environment; they get
#   the persisted user environment instead.  That is fine here because the
#   HINDSIGHT_* settings are stored in the user environment (verified by
#   dumping a WMI child's env).
function Spawn-OutsideJob($cmdline) {
    try {
        return Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
                                -Arguments @{ CommandLine = $cmdline }
    } catch {
        Say ('  WMI spawn threw: ' + $_.Exception.Message)
        return $null
    }
}

function Start-Daemon {
    Say 'starting hindsight-embed daemon (profile coding-agent)'
    $dlog = 'F:\deepseek\.hindsight-setup\daemon-start.log'
    $embed = Join-Path $bin 'hindsight-embed.exe'

    # The launcher resolves the profile directory from the *incoming*
    # USERPROFILE, and only then loads the profile file -- so a WMI child (which
    # sees the persisted USERPROFILE=C:\Users\Administrator) tries to create
    # C:\Users\Administrator\.hindsight\profiles\coding-agent.lock and dies with
    # PermissionError 13.  The profile itself already says the home is on F:,
    # so we just hand the child the same three paths up front.
    $pre = 'set "USERPROFILE=' + $home2 + '" & set "HOME=' + $home2 + '" & ' +
           'set "TEMP=' + (Join-Path $home2 'tmp') + '" & set "TMP=' + (Join-Path $home2 'tmp') + '" & '
    $r = Spawn-OutsideJob ('cmd.exe /c ' + $pre + $embed + ' -p coding-agent daemon start >> ' + $dlog + ' 2>&1')
    if ($r -and $r.ReturnValue -eq 0) {
        Say ('  spawned outside the job via WMI, pid = ' + $r.ProcessId + ' (log: daemon-start.log)')
        return
    }
    if ($r) { Say ('  WMI spawn refused (rv=' + $r.ReturnValue + ') -> falling back to in-job launch') }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = 'cmd.exe'
    $psi.Arguments = '/c ""' + $embed + '" -p coding-agent daemon start >> "' + $dlog + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        Say ('daemon start exit = ' + $p.ExitCode + ' (log: daemon-start.log)')
    } catch {
        Say ('daemon start threw: ' + $_.Exception.Message)
    }
}

# --- 1. postgres ----------------------------------------------------------
$pgProc = $null
if (-not (Test-PgUp)) { $pgProc = Start-Pg } else { Say 'pg already up on 5433' }

$ready = $false
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 1
    if (Test-PgUp) { $ready = $true; Say ('postgres ready after ' + $i + 's'); break }
}
if (-not $ready) {
    Say 'postgres NOT ready - see pg-stderr.log'
    try { Say ('  pg-stderr tail: ' + ((Get-Content (Join-Path $home2 'pg-stderr.log') -Tail 12 -ErrorAction SilentlyContinue) -join ' | ')) } catch { }
} else {
    # --- 2. extensions (idempotent) ---------------------------------------
    $psql = Join-Path $pgBin 'psql.exe'
    foreach ($ext in 'vector', 'pg_trgm') {
        & $psql $dbUrl -c ('CREATE EXTENSION IF NOT EXISTS ' + $ext + ';') 2>&1 |
            ForEach-Object { Say ('  ext ' + $ext + ': ' + $_) }
    }
}

# --- 3. daemon ------------------------------------------------------------
if ((Test-Health) -eq '') { Start-Daemon } else { Say 'daemon already healthy' }

# --- 4. supervise forever -------------------------------------------------
$lastDaemonTry = Get-Date
$lastPgTry     = Get-Date
while ($true) {
    Start-Sleep -Seconds 15
    $pgUp = Test-PgUp
    $h = Test-Health
    Say ('pg=' + $pgUp + ' health=' + $(if ($h -eq '') { 'DOWN' } else { 'UP' }))
    if (-not $pgUp -and ((Get-Date) - $lastPgTry).TotalSeconds -gt 60) {
        Say 'postgres died -> restarting'
        $lastPgTry = Get-Date
        $pgProc = Start-Pg
        Start-Sleep -Seconds 8
    }
    if ((Test-Health) -eq '' -and ((Get-Date) - $lastDaemonTry).TotalSeconds -gt 60) {
        Say 'health DOWN -> restarting daemon'
        $lastDaemonTry = Get-Date
        Start-Daemon
    }
}
