# codex-wrapper

Team wrapper for the [Codex CLI](https://github.com/openai/codex) against the apro
LiteLLM proxy (`https://litellm.ai.apro.is`). The proxy fronts all company LLMs
behind one OpenAI-compatible endpoint and requires two things from every caller: a
per-user LiteLLM virtual key (from 1Password) and an `x-github-repo` header so spend
is attributed to a project. This repo packages the working setup so you can install
`codex` the same way you installed the team `claude` wrapper — the wrapper fetches
your key, detects the current repo, keeps a local TLS shim running, and then execs
the real `codex` binary.

## Prerequisites

- **Codex CLI** — `brew install codex`
- **python3 with TLS 1.3** — `brew install python` (the shim needs a modern
  OpenSSL; the macOS system Python won't do)
- **1Password CLI (`op`)** — signed in to `aproorg.1password.eu`
- **The team `claude` wrapper working** ([aproorg/claude-wrapper](https://github.com/aproorg/claude-wrapper)) —
  codex-wrapper reuses its shared `claude-env.sh` for auth (same 1Password item,
  same repo detection). If `claude` works on your machine, `codex` will too.

## Install

```sh
git clone git@github.com:aproorg/codex-wrapper.git
cd codex-wrapper
./install.sh
```

The installer:

- copies `litellm_shim.py` and `config.toml` into `~/.codex/` (an existing
  `config.toml` is backed up to `config.toml.bak`; your `[projects]` directory-trust
  entries are carried over automatically)
- symlinks `codex` into `~/.local/bin/codex`, shadowing the real binary — a
  `git pull` in this repo updates your wrapper in place
- verifies `~/.local/bin` precedes the Homebrew bin dir on your `PATH`

Directory trust is per-user and is **not** shipped in the shared config: Codex
prompts to trust a directory on first run and writes the `[projects."<path>"]`
block into your local `~/.codex/config.toml`.

## How it works

Two Codex quirks make this more than a plain env wrapper:

1. **TLS:** Codex's bundled native-tls stack cannot reach `litellm.ai.apro.is`
   (it fails with "error sending request"; curl works fine). So a tiny local
   HTTP/1.1 → HTTPS shim (`litellm_shim.py`) listens on `127.0.0.1:8787`. Codex
   talks plaintext HTTP to localhost; the shim forwards upstream over Python's
   OpenSSL TLS and injects the required `x-github-repo` header. MCP traffic
   (`/mcp/`) is proxied through the same shim for the same reason.
2. **Config:** Codex reads `~/.codex/config.toml` rather than env vars, so the
   model defaults, profiles, MCP servers, and the shim's `base_url` live there.

On each launch the wrapper (`~/.local/bin/codex`):

1. sources the shared `claude-env.sh` from
   [aproorg/claude-wrapper](https://github.com/aproorg/claude-wrapper) (cached
   ~5 min) to fetch your LiteLLM key from 1Password and detect the current
   GitHub repo — the exact same auth path as Claude Code, deliberately **reused,
   never forked**, so key rotation and proxy changes propagate to both tools;
2. starts the shim if nothing is listening on port 8787;
3. exports `LITELLM_API_KEY` + `CODEX_GITHUB_REPO` and execs the real `codex`.

Portability note: the wrapper defaults to `SHIM_PYTHON=/opt/homebrew/bin/python3`
(Apple-Silicon Homebrew). On other setups, export `SHIM_PYTHON` pointing at any
TLS-1.3-capable `python3`. Other knobs: `SHIM_PORT` (default `8787`),
`SHIM_UPSTREAM`, `CODEX_REAL_BIN` (bypass binary discovery), `CLAUDE_ENV_URL`
(alternate env source).

## Profiles

Switch models with `codex --profile <name>` (default model: `gpt-5.4`):

| Profile | Model |
|---|---|
| `gpt5` | gpt-5.4 |
| `gpt5-pro` | gpt-5.4-pro |
| `o3` | o3 |
| `o4-mini` | o4-mini |
| `gpt56-sol` | gpt-5.6-sol |
| `gpt56-terra` | gpt-5.6-terra |
| `gpt56-luna` | gpt-5.6-luna |

## Troubleshooting

- **"error sending request" / TLS errors** — the shim isn't running or is using
  the wrong Python. Check `~/.cache/codex-shim.log`; make sure `SHIM_PYTHON`
  points at a TLS-1.3 Python. The wrapper restarts the shim automatically when
  nothing listens on port 8787: `kill $(lsof -ti tcp:8787)` then rerun `codex`.
- **1Password errors / "no LITELLM_API_KEY"** — `op signin --account aproorg.1password.eu`.
  The key lives in the same 1Password item the `claude` wrapper uses.
- **Proxy error about missing `x-github-repo`** — traffic isn't going through the
  shim (check `base_url = "http://127.0.0.1:8787/v1"` in `~/.codex/config.toml`)
  or the shim isn't injecting the header (check the shim log; each request line
  prints the header value).
- **Stale team config** — `rm ~/.cache/claude/env-remote.sh` forces a refetch of
  the shared `claude-env.sh` on next launch.
- **Verbose debugging** — `CLAUDE_DEBUG=1 codex`.
