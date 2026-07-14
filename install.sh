#!/usr/bin/env bash
# install.sh — macOS/Linux installer for codex-wrapper
#
# Usage:
#   git clone git@github.com:aproorg/codex-wrapper.git
#   cd codex-wrapper && ./install.sh
#
# What it does:
#   1. Checks prerequisites (real codex binary, TLS-1.3 python3, op, curl)
#   2. Copies litellm_shim.py + config.toml into ~/.codex/
#      (an existing config.toml is backed up to config.toml.bak and its
#      per-user [projects] trust blocks are carried over)
#   3. Symlinks the `codex` wrapper into ~/.local/bin/codex so it shadows
#      the real binary — `git pull` in this repo updates the wrapper in place
#
# Options:
#   CODEX_FORCE=1    Skip the config.toml backup prompt-free (still writes .bak)

set -euo pipefail

# ── Output helpers (mirrors claude-wrapper/install.sh) ──────────────────────
if [[ -t 2 ]]; then
  _C_INFO=$'\033[34m'; _C_OK=$'\033[32m'; _C_WARN=$'\033[33m'; _C_ERR=$'\033[31m'; _C_RST=$'\033[0m'
else
  _C_INFO=""; _C_OK=""; _C_WARN=""; _C_ERR=""; _C_RST=""
fi
info()  { printf "  ${_C_INFO}[INFO]${_C_RST}  %s\n" "$1" >&2; }
ok()    { printf "  ${_C_OK}[OK]${_C_RST}    %s\n" "$1" >&2; }
warn()  { printf "  ${_C_WARN}[WARN]${_C_RST}  %s\n" "$1" >&2; }
die()   { printf "  ${_C_ERR}[ERROR]${_C_RST} %s\n" "$1" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ── Locations ────────────────────────────────────────────────────────────────
REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CODEX_DIR="$HOME/.codex"
WRAPPER_LINK="$BIN_DIR/codex"
SHIM_PYTHON="${SHIM_PYTHON:-/opt/homebrew/bin/python3}"
SHIM_PORT="${SHIM_PORT:-8787}"

# Portable realpath (macOS lacks readlink -f). Mirrors the wrapper's helper.
_realpath() {
  local p="$1"
  [[ -e "$p" ]] || return 1
  while [[ -L "$p" ]]; do
    local dir
    dir="$(cd -P "$(dirname "$p")" && pwd)"
    p="$(readlink "$p")"
    [[ "$p" != /* ]] && p="$dir/$p"
  done
  cd -P "$(dirname "$p")" && echo "$(pwd)/$(basename "$p")"
}

# ── Prerequisites ────────────────────────────────────────────────────────────
find_real_codex() {
  local IFS=:
  local self=""
  self="$(_realpath "$WRAPPER_LINK" 2>/dev/null || true)"
  for dir in $PATH; do
    local candidate="$dir/codex"
    [[ -x "$candidate" && ! -d "$candidate" ]] || continue
    local resolved
    resolved="$(_realpath "$candidate" 2>/dev/null || true)"
    [[ -n "$self" && "$resolved" == "$self" ]] && continue
    [[ "$resolved" == "$REPO_DIR/codex" ]] && continue
    echo "$candidate"
    return 0
  done
  return 1
}

check_prerequisites() {
  have curl || die "curl is required"

  REAL_CODEX="$(find_real_codex || true)"
  [[ -n "$REAL_CODEX" ]] || die "Codex CLI not found on PATH. Install it first: brew install codex"
  info "Real codex binary: $REAL_CODEX"

  if [[ -x "$SHIM_PYTHON" ]]; then
    if "$SHIM_PYTHON" -c 'import ssl; raise SystemExit(0 if ssl.HAS_TLSv1_3 else 1)' 2>/dev/null; then
      ok "TLS 1.3 python3 found at $SHIM_PYTHON"
    else
      die "$SHIM_PYTHON lacks TLS 1.3 support — the shim needs it to reach the proxy. brew install python"
    fi
  else
    die "python3 not found at $SHIM_PYTHON — brew install python, or point SHIM_PYTHON at a TLS-1.3 python3 and re-run"
  fi

  if have op; then
    if op whoami --account aproorg.1password.eu >/dev/null 2>&1; then
      ok "1Password CLI signed in (aproorg.1password.eu)"
    else
      warn "1Password CLI found but not signed in — run: op signin --account aproorg.1password.eu"
    fi
  else
    die "1Password CLI (op) is required — the wrapper reads the LiteLLM key from 1Password. Install: https://developer.1password.com/docs/cli/get-started/"
  fi

  # The wrapper reuses claude-wrapper's remote claude-env.sh for auth. If the
  # team claude wrapper already works on this machine, codex will too.
  if [[ ! -x "$BIN_DIR/claude" ]]; then
    warn "No claude wrapper at $BIN_DIR/claude — codex-wrapper shares its auth setup."
    warn "If codex can't fetch a key, install claude-wrapper first (github.com/aproorg/claude-wrapper)."
  fi
}

# ── ~/.codex: shim + shared config ───────────────────────────────────────────
install_codex_dir() {
  mkdir -p "$CODEX_DIR"

  cp "$REPO_DIR/litellm_shim.py" "$CODEX_DIR/litellm_shim.py"
  ok "Installed $CODEX_DIR/litellm_shim.py"

  local target="$CODEX_DIR/config.toml"
  if [[ -f "$target" ]]; then
    cp "$target" "$target.bak"
    info "Backed up existing config to $target.bak"
    cp "$REPO_DIR/config.toml" "$target"
    # Carry over per-user [projects."<path>"] trust blocks so directories the
    # user already trusted don't re-prompt after the upgrade.
    local projects
    projects="$(awk '/^\[projects[].]/ { in_proj=1; print; next } /^\[/ { in_proj=0 } in_proj { print }' "$target.bak")"
    if [[ -n "$projects" ]]; then
      {
        echo ""
        echo "# ---- Per-user directory trust (carried over by install.sh) ----"
        echo "$projects"
      } >> "$target"
      ok "Wrote $target (carried over your [projects] trust entries)"
    else
      ok "Wrote $target"
    fi
    warn "Other local customizations live in $target.bak — merge back by hand if needed"
  else
    cp "$REPO_DIR/config.toml" "$target"
    ok "Wrote $target"
    info "Codex will prompt to trust each directory on first run (writes [projects] blocks locally)"
  fi
}

# ── ~/.local/bin/codex: symlink onto PATH ahead of the real binary ──────────
install_wrapper() {
  mkdir -p "$BIN_DIR"
  if [[ -e "$WRAPPER_LINK" && ! -L "$WRAPPER_LINK" ]]; then
    local backup="$WRAPPER_LINK.backup.$(date +%s)"
    cp -P "$WRAPPER_LINK" "$backup"
    info "Backed up existing $WRAPPER_LINK to $backup"
    rm -f "$WRAPPER_LINK"
  fi
  ln -sf "$REPO_DIR/codex" "$WRAPPER_LINK"
  ok "Symlinked $WRAPPER_LINK -> $REPO_DIR/codex (git pull updates it)"
}

check_path_order() {
  local real_dir wrapper_pos=-1 real_pos=-1 i=0
  real_dir="$(dirname "$REAL_CODEX")"
  local IFS=:
  for dir in $PATH; do
    [[ "$dir" == "$BIN_DIR" && $wrapper_pos -lt 0 ]] && wrapper_pos=$i
    [[ "$dir" == "$real_dir" && $real_pos -lt 0 ]] && real_pos=$i
    i=$((i + 1))
  done
  if [[ $wrapper_pos -lt 0 ]]; then
    warn "$BIN_DIR is not on PATH — add it BEFORE $real_dir in your shell profile:"
    warn "  export PATH=\"$BIN_DIR:\$PATH\""
  elif [[ $real_pos -ge 0 && $wrapper_pos -gt $real_pos ]]; then
    warn "$BIN_DIR comes AFTER $real_dir on PATH — the real codex will shadow the wrapper."
    warn "Move it earlier in your shell profile: export PATH=\"$BIN_DIR:\$PATH\""
  else
    ok "$BIN_DIR precedes $real_dir on PATH"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo >&2
  echo "  Codex Wrapper Installer (apro LiteLLM proxy)" >&2
  echo "  $(printf '─%.0s' {1..45})" >&2
  echo >&2

  check_prerequisites
  install_codex_dir
  install_wrapper
  check_path_order

  # A shim from a previous install may still be running with old code.
  if (exec 3<>"/dev/tcp/127.0.0.1/$SHIM_PORT") 2>/dev/null; then
    warn "A shim is already running on 127.0.0.1:$SHIM_PORT — restart it to pick up the new version:"
    warn "  kill \$(lsof -ti tcp:$SHIM_PORT) ; the wrapper relaunches it on next run"
  fi

  echo >&2
  ok "Installation complete!"
  cat <<EOF >&2

  Quick test:
    which codex          # should show $WRAPPER_LINK
    codex exec "say hi"  # goes through the shim to litellm.ai.apro.is

  Debug:
    CLAUDE_DEBUG=1 codex          # verbose auth/env resolution
    tail -f ~/.cache/codex-shim.log
    rm ~/.cache/claude/env-remote.sh   # force refetch of shared auth config

EOF
}

main "$@"
