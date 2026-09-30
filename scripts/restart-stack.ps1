$ErrorActionPreference = 'Continue'
$log = 'F:\deepseek\.hindsight-setup\restart-stack.log'
function Say($m) {
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m
    Write-Output $line
    Add-Content -LiteralPath $log -Value $line
}

$bin      = 'F:\deepseek\.hindsight-bin'
$home2    = 'F:\deepseek\.hindsight-home'
$pgBin    = 'C:\Users\Administrator\.pg0\installation\18.1.0\bin'
$pgData   = Join-Path $home2 'pgdata3'
$dbUrl    = 'postgresql://hindsight:hindsight@127.0.0.1:5433/hindsight'
$apiPort  = '9077'

# --- environment the daemon + postgres need -------------------------------
$env:HINDSIGHT_SERVER_MODE          = 'daemon'
$env:HINDSIGHT_DAEMON_PROFILE       = 'coding-agent'
$env:HINDSIGHT_API_PORT             = $apiPort
$env:HINDSIGHT_EMBED_VERSION        = '0.10.2'
$env:HINDSIGHT_API_DATABASE_URL     = $dbUrl
$env:HINDSIGHT_API_DATABASE_URL_RAW = $dbUrl
$env:HINDSIGHT_API_LLM_PROVIDER     = 'deepseek'
$env:HINDSIGHT_API_LLM_MODEL        = 'deepseek-chat'
$env:HINDSIGHT_API_LLM_BASE_URL     = 'https://api.deepseek.com'
$env:HINDSIGHT_API_LLM_API_KEY      = $env:DEEPSEEK_API_KEY
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
$env:PATH                           = $bin + ';' + $pgBin + ';' + $env:PATH
$env:TEMP                           = 'C:\Users\Administrator\AppData\Local\Temp'
$env:TMP                            = 'C:\Users\Administrator\AppData\Local\Temp'

Say ('pg listening before start: ' + [bool](netstat -ano | Select-String ':5433\s.*LISTENING'))

# --- 1. postgres ----------------------------------------------------------
if (-not (netstat -ano | Select-String ':5433\s.*LISTENING')) {
    $pidFile = Join-Path $pgData 'postmaster.pid'
    if (Test-Path $pidFile) {
        $stalePid = (Get-Content $pidFile -First 1).Trim()
        $alive = Get-Process -Id $stalePid -ErrorAction SilentlyContinue
        if (-not $alive) { Say ('removing stale postmaster.pid for dead pid ' + $stalePid); Remove-Item -LiteralPath $pidFile -Force }
    }
    Say 'starting postgres.exe on 5433'
    Start-Process -FilePath (Join-Path $pgBin 'postgres.exe') -ArgumentList @('-D', $pgData, '-p', '5433') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $home2 'pg-stdout.log') -RedirectStandardError (Join-Path $home2 'pg-stderr.log')
}

$ready = $false
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 1
    $probe = & (Join-Path $pgBin 'pg_isready.exe') -h 127.0.0.1 -p 5433 2>&1
    if ($probe -match 'accepting connections') { $ready = $true; Say ('postgres ready after ' + $i + 's'); break }
}
if (-not $ready) { Say 'postgres NOT ready - aborting'; exit 1 }

# --- 2. role/database/extensions (idempotent) -----------------------------
$psql = Join-Path $pgBin 'psql.exe'
$sql = "SELECT 1 FROM pg_database WHERE datname='hindsight'"
$exists = (& $psql $dbUrl -tAc $sql 2>&1) -join ' '
Say ('database exists check -> ' + $exists.Trim())
if ($exists.Trim() -ne '1') {
    Say 'creating role + database hindsight'
    & $psql 'postgresql://postgres@127.0.0.1:5433/postgres' -c "CREATE ROLE hindsight LOGIN PASSWORD 'hindsight' SUPERUSER;" 2>&1 | ForEach-Object { Say ('  ' + $_) }
    & $psql 'postgresql://postgres@127.0.0.1:5433/postgres' -c 'CREATE DATABASE hindsight OWNER hindsight;' 2>&1 | ForEach-Object { Say ('  ' + $_) }
}
foreach ($ext in 'vector', 'pg_trgm') {
    & $psql $dbUrl -c ('CREATE EXTENSION IF NOT EXISTS ' + $ext + ';') 2>&1 | ForEach-Object { Say ('  ext ' + $ext + ': ' + $_) }
}
Say ('extensions: ' + ((& $psql $dbUrl -tAc "SELECT string_agg(extname, ',') FROM pg_extension" 2>&1) -join ' ').Trim())

# --- 3. hindsight daemon --------------------------------------------------
Say 'starting hindsight-embed daemon (this can take a while: uvx resolves hindsight-api)'
$daemonLog = 'F:\deepseek\.hindsight-setup\daemon-start.log'
& (Join-Path $bin 'hindsight-embed.exe') -p coding-agent daemon start *>&1 | Tee-Object -FilePath $daemonLog | ForEach-Object { Say ('  daemon: ' + $_) }
Say ('daemon start exit = ' + $LASTEXITCODE)

# --- 4. wait for health ---------------------------------------------------
for ($i = 1; $i -le 60; $i++) {
    Start-Sleep -Seconds 5
    try {
        $r = Invoke-WebRequest ('http://127.0.0.1:' + $apiPort + '/health') -UseBasicParsing -TimeoutSec 4
        Say ('HEALTH OK after ' + ($i * 5) + 's: ' + $r.Content)
        exit 0
    } catch {
        if ($i % 6 -eq 0) { Say ('  waiting... (' + ($i * 5) + 's) ' + $_.Exception.Message) }
    }
}
Say 'health never came up - dumping daemon log tail'
Get-Content (Join-Path $home2 '.hindsight\profiles\coding-agent.log') -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Say ('  ' + $_) }
exit 1
