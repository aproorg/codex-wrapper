# codexstart.ps1 — Process wrapper for Codex CLI (Windows)
#
# Windows counterpart of the `codex` bash wrapper, mirroring how
# claudestart.ps1 mirrors claude-env.sh: it resolves the LiteLLM key from
# 1Password (same item, same local.env, same key cache as the claude
# wrapper), detects the current GitHub repo for the x-github-repo header,
# and launches the real `codex` with LITELLM_API_KEY + CODEX_GITHUB_REPO
# exported.
#
# Install:  irm https://raw.githubusercontent.com/aproorg/codex-wrapper/main/install.ps1 | iex
# Update:   Remove-Item "$env:LOCALAPPDATA\claude\env-remote.sh"
# Debug:    $env:CLAUDE_DEBUG = "1"; codexstart

# ============================================================================
# Configuration (mirrored from claude-env.sh / claudestart.ps1)
# ============================================================================
$OP_Account = "aproorg.1password.eu"
$OP_Item = "op://Employee/ai.apro.is litellm"
$OP_Field = "API Key"

$CacheTTL_Seconds = 43200  # 12 hours for API keys
$ConfigTTL_Seconds = 300   # 5 minutes for remote config

# ============================================================================
# Cache directory — deliberately SHARED with the claude wrapper so keys and
# remote config are fetched once for both tools.
# ============================================================================
$CacheDir = "$env:LOCALAPPDATA\claude"
if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

# ============================================================================
# Handle --clear-cache
# ============================================================================
if ($args -contains "--clear-cache") {
    Get-ChildItem -Path $CacheDir -Filter "*.key" -ErrorAction SilentlyContinue | Remove-Item -Force
    $RemoteCache = Join-Path $CacheDir "env-remote.sh"
    if (Test-Path $RemoteCache) { Remove-Item $RemoteCache -Force }
    Write-Host "Codex env + API key cache cleared" -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# Remote config fetch + cache (same claude-env.sh, same cache file as the
# claude wrapper — single source of truth for the 1Password item)
# ============================================================================
$_RemoteUrl = if ($env:CLAUDE_ENV_URL) { $env:CLAUDE_ENV_URL } else { "https://raw.githubusercontent.com/aproorg/claude-wrapper/main/claude-env.sh" }
$_RemoteCache = Join-Path $CacheDir "env-remote.sh"

$_NeedsFetch = $true
if (Test-Path $_RemoteCache) {
    $_Age = ((Get-Date) - (Get-Item $_RemoteCache).LastWriteTime).TotalSeconds
    if ($_Age -lt $ConfigTTL_Seconds) { $_NeedsFetch = $false }
}

if ($_NeedsFetch) {
    try {
        $_tmp = "$_RemoteCache.tmp.$PID"
        Invoke-WebRequest -Uri $_RemoteUrl -OutFile $_tmp -TimeoutSec 10 -ErrorAction Stop
        # Integrity check: reject dangerous patterns
        $_content = Get-Content $_tmp -Raw
        if ($_content -match '(rm\s+-rf\s+/|curl.*\|\s*(ba)?sh|eval\s)') {
            [Console]::Error.WriteLine("ERROR: Remote config failed integrity check")
            Remove-Item $_tmp -Force -ErrorAction SilentlyContinue
            exit 1
        }
        Move-Item $_tmp $_RemoteCache -Force
    } catch {
        Remove-Item "$_RemoteCache.tmp.$PID" -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $_RemoteCache)) {
            [Console]::Error.WriteLine("ERROR: Cannot fetch config from $_RemoteUrl (no cache)")
            exit 1
        }
        if ($env:CLAUDE_DEBUG -eq "1") {
            $_StaleAge = [int]((Get-Date) - (Get-Item $_RemoteCache).LastWriteTime).TotalSeconds
            [Console]::Error.WriteLine("Warning: Using stale cached config (${_StaleAge}s old, fetch failed)")
        }
    }
}

# Parse remote config for key overrides (remote defaults -> local overrides)
if (Test-Path $_RemoteCache) {
    foreach ($_line in Get-Content $_RemoteCache) {
        if ($_line -match '^\s*(?:export\s+)?(\w+)="(.*?)"\s*$') {
            switch ($Matches[1]) {
                "OP_ACCOUNT" { $OP_Account = $Matches[2] }
                "OP_ITEM"    { $OP_Item = $Matches[2] }
            }
        }
    }
}
Remove-Variable _RemoteUrl, _RemoteCache, _NeedsFetch, _Age, _tmp, _content, _StaleAge, _line -ErrorAction SilentlyContinue

# ── Local overrides (same local.env the claude wrapper's install writes) ────
$_LocalEnvPath = "$env:APPDATA\claude\local.env"
if (Test-Path $_LocalEnvPath) {
    foreach ($line in Get-Content $_LocalEnvPath) {
        if ($line -match '^(OP_ITEM|OP_FIELD|OP_ACCOUNT)="(.*)"') {
            switch ($Matches[1]) {
                "OP_ITEM"    { $OP_Item = $Matches[2] }
                "OP_FIELD"   { $OP_Field = $Matches[2] }
                "OP_ACCOUNT" { $OP_Account = $Matches[2] }
            }
        }
    }
}
Remove-Variable _LocalEnvPath -ErrorAction SilentlyContinue

# Defensive migration: legacy OP_ITEM with the field baked into the path
# (op://V/Item/API Key). Item path is always Vault/Item; the rest is the field.
if ($OP_Item) {
    $_opStripped = $OP_Item -replace '^op://', ''
    $_opSegs = $_opStripped.Split('/')
    if ($_opSegs.Count -gt 2) {
        $OP_Item = "op://$($_opSegs[0])/$($_opSegs[1])"
        $OP_Field = ($_opSegs | Select-Object -Skip 2) -join '/'
    }
    Remove-Variable _opStripped, _opSegs -ErrorAction SilentlyContinue
}

# ============================================================================
# Project / repo detection (mirrors claudestart.ps1)
# ============================================================================
function Sanitize-Name {
    param([string]$Name)
    $cleaned = ($Name -replace '[^a-zA-Z0-9_.\-]', '') -replace '^\.+', ''
    if (-not $cleaned) { return 'unnamed' }
    return $cleaned
}

function Get-CodexProject {
    $raw = ""
    if ($env:CLAUDE_PROJECT) {
        $raw = $env:CLAUDE_PROJECT
    } else {
        try {
            $remote = git remote get-url origin 2>$null
            if ($remote) {
                $raw = ($remote -split "/" | Select-Object -Last 1) -replace "\.git$", ""
            }
        } catch {}
        if (-not $raw) { $raw = (Split-Path -Leaf (Get-Location)) }
    }
    return (Sanitize-Name $raw)
}

# Returns "org/repo" from git origin, or empty string. Used for the
# x-github-repo header. Override via CODEX_GITHUB_REPO.
function Get-GitHubRepo {
    if ($env:CODEX_GITHUB_REPO) { return $env:CODEX_GITHUB_REPO }

    $url = ""
    try {
        $url = git remote get-url origin 2>$null
    } catch {}
    if (-not $url) { return "" }

    if ($url -match '://') {
        $url = $url -replace '^[^:]+://[^/]+/', ''
    } elseif ($url -match ':') {
        $url = $url -replace '^[^:]*:', ''
    }
    $url = $url -replace '\.git$', ''

    $segs = $url.Split('/')
    if ($segs.Count -ge 2) {
        return "$($segs[$segs.Count - 2])/$($segs[$segs.Count - 1])"
    }
    return ""
}

# ============================================================================
# API Key Management (same cache files as claudestart.ps1)
# ============================================================================
function Invoke-OpRead {
    param([string]$Path)
    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        try {
            $stdout = & op --account $OP_Account read $Path 2>$stderrFile
        } catch {
            return @{ Key = $null; Err = "op invocation failed: $($_.Exception.Message)" }
        }
        $stderr = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue) -replace '\s+$', ''
        $key = if ($stdout) { (@($stdout) -join "`n").Trim() } else { $null }
        return @{ Key = $key; Err = $stderr }
    } finally {
        Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ApiKey {
    param([string]$Project)

    $cacheFile = Join-Path $CacheDir "$Project.key"

    if ((Test-Path $cacheFile) -and (Get-Item $cacheFile).Length -gt 0) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalSeconds -lt $CacheTTL_Seconds) {
            if ($env:CLAUDE_DEBUG -eq "1") { [Console]::Error.WriteLine("key=cached") }
            return (Get-Content $cacheFile -Raw).Trim()
        }
    }

    $key = $null
    $attempts = @()

    # Project-specific field first, then the fallback field
    $projectPath = "$OP_Item/$Project"
    $r = Invoke-OpRead $projectPath
    $attempts += @{ Path = $projectPath; Err = $r.Err }
    if ($r.Key) { $key = $r.Key }

    if (-not $key) {
        $defaultPath = "$OP_Item/$OP_Field"
        $r = Invoke-OpRead $defaultPath
        $attempts += @{ Path = $defaultPath; Err = $r.Err }
        if ($r.Key) {
            $key = $r.Key
            if ($env:CLAUDE_DEBUG -eq "1") {
                [Console]::Error.WriteLine("Note: No key for project '$Project', using default field '$OP_Field'")
            }
        }
    }

    if (-not $key) {
        [Console]::Error.WriteLine("ERROR: Failed to retrieve API key from 1Password")
        if ($env:CLAUDE_DEBUG -eq "1") {
            [Console]::Error.WriteLine("  account: $OP_Account")
            [Console]::Error.WriteLine("  paths tried (with op stderr):")
            foreach ($a in $attempts) {
                [Console]::Error.WriteLine("    - $($a.Path)")
                if ($a.Err) {
                    foreach ($line in ($a.Err -split "`r?`n")) {
                        if ($line) { [Console]::Error.WriteLine("        $line") }
                    }
                }
            }
        } else {
            [Console]::Error.WriteLine("  Try: op signin --account $OP_Account   (or `$env:CLAUDE_DEBUG = `"1`" for details)")
        }
        return $null
    }

    $tmpFile = "$cacheFile.tmp.$PID"
    $key | Out-File -FilePath $tmpFile -NoNewline -Encoding UTF8
    Move-Item $tmpFile $cacheFile -Force

    if ($env:CLAUDE_DEBUG -eq "1") { [Console]::Error.WriteLine("key=fetched") }
    return $key
}

# ============================================================================
# CA bundle (codex-specific)
# ============================================================================
# On macOS, Codex (rustls) fails to reach the proxy when it verifies through the
# platform verifier, and must be pointed at a PEM bundle via
# CODEX_CA_CERTIFICATE. On Windows we deliberately do NOT probe for a bundle:
# the Windows system root store is a different implementation that is expected
# to work, and it is also where corporate/MDM CAs live — pinning a static
# bundle here could break a machine behind a TLS-inspecting proxy.
#
# So we only honour an explicit override. If Codex on Windows turns out to hit
# the same defect ("Connection failed: error sending request"), set:
#   $env:CODEX_CA_CERTIFICATE = "C:\path\to\ca-bundle.crt"
# Git for Windows ships one at <git>\mingw64\etc\ssl\certs\ca-bundle.crt.
function Set-CodexCaBundle {
    if ($env:CODEX_CA_CERTIFICATE) {
        if (-not (Test-Path -LiteralPath $env:CODEX_CA_CERTIFICATE)) {
            [Console]::Error.WriteLine("Warning: CODEX_CA_CERTIFICATE does not exist: $env:CODEX_CA_CERTIFICATE")
        }
        return
    }
    if ($env:SSL_CERT_FILE) {
        if (Test-Path -LiteralPath $env:SSL_CERT_FILE) {
            $env:CODEX_CA_CERTIFICATE = $env:SSL_CERT_FILE
            return
        }
        [Console]::Error.WriteLine("Warning: SSL_CERT_FILE does not exist: $env:SSL_CERT_FILE")
    }
}

# ============================================================================
# Main
# ============================================================================
$Project = Get-CodexProject

if (-not $env:LITELLM_API_KEY) {
    $apiKey = Get-ApiKey -Project $Project
    if (-not $apiKey) { exit 1 }
    $env:LITELLM_API_KEY = $apiKey
}

$githubRepo = Get-GitHubRepo
$env:CODEX_GITHUB_REPO = if ($githubRepo) { $githubRepo } else { "aproorg/code" }

Set-CodexCaBundle

if ($env:CLAUDE_DEBUG -eq "1") {
    $caDesc = if ($env:CODEX_CA_CERTIFICATE) { $env:CODEX_CA_CERTIFICATE } else { "<system roots>" }
    [Console]::Error.WriteLine("Codex: project=$Project repo=$($env:CODEX_GITHUB_REPO) ca=$caDesc")
}

# Launch the real Codex CLI (pass through any arguments)
& codex @args
exit $LASTEXITCODE
