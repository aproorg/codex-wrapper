# install.ps1 — Windows installer for codex-wrapper
#
# Usage:
#   irm https://raw.githubusercontent.com/aproorg/codex-wrapper/main/install.ps1 | iex
#
# Override base URL (test from a branch):
#   $env:CODEX_WRAPPER_BASE = "https://raw.githubusercontent.com/aproorg/codex-wrapper/<branch>"
#   irm https://raw.githubusercontent.com/aproorg/codex-wrapper/<branch>/install.ps1 | iex

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# ── Output helpers (mirrors claude-wrapper/install.ps1) ─────────────────────
function Write-Info($msg) { Write-Host "  [INFO]  $msg" -ForegroundColor Blue }
function Write-Ok($msg)   { Write-Host "  [OK]    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [ERROR] $msg" -ForegroundColor Red; exit 1 }

# ── Configuration ───────────────────────────────────────────────────────────
$BaseUrl = if ($env:CODEX_WRAPPER_BASE) { $env:CODEX_WRAPPER_BASE } else { "https://raw.githubusercontent.com/aproorg/codex-wrapper/main" }

$InstallDir = "$env:LOCALAPPDATA\Programs\codex-wrapper"
$CodexDir   = "$env:USERPROFILE\.codex"
$Ps1Path    = "$InstallDir\codexstart.ps1"
$CmdPath    = "$InstallDir\codexstart.cmd"

# ── Prerequisites ───────────────────────────────────────────────────────────
function Have($cmd) {
    $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Check-Prerequisites {
    if (-not (Have 'codex')) {
        Write-Err "Codex CLI not found on PATH. Install it first: npm install -g @openai/codex"
    }
    $python = if ($env:SHIM_PYTHON) { $env:SHIM_PYTHON } else { "python" }
    if (Have $python) {
        try {
            & $python -c "import ssl; raise SystemExit(0 if ssl.HAS_TLSv1_3 else 1)" 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "TLS 1.3 Python found ($python)"
            } else {
                Write-Err "'$python' lacks TLS 1.3 support — the shim needs it. Install: winget install Python.Python.3.12"
            }
        } catch {
            Write-Err "Could not run '$python' — check your Python install"
        }
    } else {
        Write-Err "Python 3 not found — the TLS shim needs it. Install: winget install Python.Python.3.12 (or set `$env:SHIM_PYTHON)"
    }
    if (-not (Have 'op')) {
        Write-Warn "1Password CLI (op) not found — API key management will not work."
        Write-Warn "Install: https://developer.1password.com/docs/cli/get-started/"
    }
    if (-not (Have 'git')) {
        Write-Warn "git not found — repo detection will fall back to the default attribution"
    }
}

# ── PATH management ─────────────────────────────────────────────────────────
function Ensure-OnPath($dir) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $normalized = ($userPath -split ';' | ForEach-Object { $_.TrimEnd('\').ToLower() })
    if ($normalized -contains $dir.TrimEnd('\').ToLower()) {
        Write-Ok "$dir is already on user PATH"
        return
    }
    $newPath = if ($userPath) { "$userPath;$dir" } else { $dir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Ok "Added $dir to user PATH"
    Write-Warn "Restart your terminal for PATH changes to take effect"
}

# ── Download helper ─────────────────────────────────────────────────────────
function Fetch-File($name, $dest) {
    Invoke-WebRequest -Uri "$BaseUrl/$name" -OutFile $dest -UseBasicParsing -TimeoutSec 30
    Write-Ok "Wrote $dest"
}

# ── ~/.codex: shim + shared config ──────────────────────────────────────────
function Install-CodexDir {
    if (-not (Test-Path $CodexDir)) { New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null }

    Fetch-File "litellm_shim.py" "$CodexDir\litellm_shim.py"

    $target = "$CodexDir\config.toml"
    if (Test-Path $target) {
        Copy-Item $target "$target.bak" -Force
        Write-Info "Backed up existing config to $target.bak"
        Fetch-File "config.toml" $target
        # Carry over per-user [projects."<path>"] trust blocks so directories
        # the user already trusted don't re-prompt after the upgrade.
        $projects = @()
        $inProj = $false
        foreach ($line in Get-Content "$target.bak") {
            if ($line -match '^\[projects[\].]') { $inProj = $true; $projects += $line; continue }
            if ($line -match '^\[') { $inProj = $false }
            if ($inProj) { $projects += $line }
        }
        if ($projects.Count -gt 0) {
            Add-Content -Path $target -Value ""
            Add-Content -Path $target -Value "# ---- Per-user directory trust (carried over by install.ps1) ----"
            Add-Content -Path $target -Value ($projects -join "`n")
            Write-Ok "Carried over your [projects] trust entries"
        }
        Write-Warn "Other local customizations live in $target.bak — merge back by hand if needed"
    } else {
        Fetch-File "config.toml" $target
        Write-Info "Codex will prompt to trust each directory on first run (writes [projects] blocks locally)"
    }
}

# ── Main ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Codex Wrapper Installer (apro LiteLLM proxy)" -ForegroundColor White
Write-Host ("  " + ("─" * 45))
Write-Host ""

Check-Prerequisites

Write-Info "Install dir: $InstallDir"
Write-Info "Source:      $BaseUrl"

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

Install-CodexDir

Write-Info "Downloading codexstart.ps1..."
Fetch-File "codexstart.ps1" $Ps1Path

# .cmd shim so users can type just `codexstart`
$shimContent = "@powershell -ExecutionPolicy Bypass -File `"%~dp0codexstart.ps1`" %*`r`n"
Set-Content -Path $CmdPath -Value $shimContent -Encoding ASCII -NoNewline
Write-Ok "Wrote $CmdPath"

Ensure-OnPath $InstallDir

Write-Host ""
Write-Ok "Installation complete!"
Write-Host @"

  The codexstart command launches Codex CLI with team config
  (LiteLLM key from 1Password, x-github-repo attribution, local TLS shim).

  Commands:
    Verify:         Get-Command codexstart
    Run:            codexstart
    Debug:          `$env:CLAUDE_DEBUG = "1"; codexstart
    Shim log:       Get-Content "`$env:LOCALAPPDATA\claude\codex-shim.log" -Tail 20
    Force refresh:  Remove-Item "`$env:LOCALAPPDATA\claude\env-remote.sh"

"@
