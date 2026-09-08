# codex-wrapper

Team wrapper for the [Codex CLI](https://github.com/openai/codex) against the apro
LiteLLM proxy (`https://litellm.ai.apro.is`). The proxy fronts all company LLMs
behind one OpenAI-compatible endpoint and requires two things from every caller: a
per-user LiteLLM virtual key (from 1Password) and an `x-github-repo` header so spend
is attributed to a project. This repo packages the working setup so you can install
`codex` the same way you installed the team `claude` wrapper — the wrapper fetches
your key, detects the current repo, and then execs the real `codex` binary.

## Prerequisites

- **Codex CLI** — `brew install codex` (macOS) / `npm install -g @openai/codex` (Windows)
- **1Password CLI (`op`)** — signed in to `aproorg.1password.eu`
- **The team `claude` wrapper working** ([aproorg/claude-wrapper](https://github.com/aproorg/claude-wrapper)) —
  codex-wrapper reuses its shared `claude-env.sh` for auth (same 1Password item,
  same repo detection). If `claude` works on your machine, `codex` will too.

## Install

### macOS / Linux / WSL

```sh
git clone git@github.com:aproorg/codex-wrapper.git
cd codex-wrapper
./install.sh
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/aproorg/codex-wrapper/main/install.ps1 | iex
```

On Windows the command is **`codexstart`** (mirroring the claude wrapper's
`claudestart`): it installs `codexstart.ps1` + a `.cmd` shim to
`%LOCALAPPDATA%\Programs\codex-wrapper` and adds that to your user PATH, and
puts the config into `%USERPROFILE%\.codex\`. It shares the claude
wrapper's key cache and `local.env` (`%APPDATA%\claude\local.env`), so if
`claudestart` works, `codexstart` will too.

Both installers:

- copy `config.toml` into `~/.codex/` (an existing `config.toml` is backed up to
  `config.toml.bak`; your `[projects]` directory-trust entries are carried over
  automatically)
- put the wrapper on your PATH — on macOS/Linux by symlinking `codex` into
  `~/.local/bin/codex` so it shadows the real binary (a `git pull` in this repo
  updates your wrapper in place); on Windows as the separate `codexstart` command

Directory trust is per-user and is **not** shipped in the shared config: Codex
prompts to trust a directory on first run and writes the `[projects."<path>"]`
block into your local `~/.codex/config.toml`.

## How it works

On each launch the wrapper (`~/.local/bin/codex` on macOS/Linux, `codexstart`
on Windows):

1. resolves your LiteLLM key and the current GitHub repo the same way the
   claude wrapper does — the bash wrapper sources the shared `claude-env.sh`
   from [aproorg/claude-wrapper](https://github.com/aproorg/claude-wrapper)
   (cached ~5 min); `codexstart.ps1` mirrors `claudestart.ps1`, sharing its
   key cache and `local.env`. Auth is deliberately **reused, never forked**,
   so key rotation and proxy changes propagate to both tools;
2. resolves a CA bundle into `CODEX_CA_CERTIFICATE` (see below);
3. exports `LITELLM_API_KEY` + `CODEX_GITHUB_REPO` and execs the real `codex`.

Everything else lives in `config.toml`, because Codex reads
`~/.codex/config.toml` rather than env vars: the `base_url`, model defaults,
profiles, and MCP servers. Codex sends the required `x-github-repo` header
itself via the provider's `env_http_headers`, reading it from
`CODEX_GITHUB_REPO`.

### The CA bundle workaround

Codex is rustls-based, and on macOS it **cannot reach the proxy when it
verifies through the system trust store** — every request fails with a bare
`Connection failed: error sending request` and Codex retries forever. This is
not a proxy problem and not a certificate problem:

- the proxy serves an ordinary public chain (`ai.apro.is` → `Amazon RSA 2048
  M04` → `Amazon Root CA 1`), TLS 1.3, and `openssl verify` returns 0;
- `Amazon Root CA 1` *is* in the macOS keychain;
- in the very same failing Codex process, TLS to other hosts succeeds.

Pointing Codex at a PEM bundle fixes it outright, which is what
`set_codex_ca_bundle` in the wrapper does — on macOS `/etc/ssl/cert.pem`, on
Linux the distro bundle. We set `CODEX_CA_CERTIFICATE` rather than exporting
`SSL_CERT_FILE`, because the wrapper execs Codex, which spawns subprocesses
(git, python, curl) whose TLS a global `SSL_CERT_FILE` would also change.

It is **non-fatal by design**: if no bundle is found the wrapper leaves the
variable unset and lets Codex fall back to system roots.

> **Behind a TLS-inspecting proxy?** A static OS bundle will not contain your
> corporate CA. Set `SSL_CERT_FILE` (or `CODEX_CA_CERTIFICATE`) to a bundle
> that does — the wrapper honours either and will not override it.

**Windows is untested.** The Windows root store is a different implementation
that is expected to work, and it is also where corporate/MDM CAs live, so
`codexstart.ps1` deliberately does **not** auto-probe for a bundle — it only
honours an explicit override. If Windows turns out to hit the same defect, set
a bundle by hand and open an issue so we can automate it:

```powershell
$env:CODEX_CA_CERTIFICATE = "C:\Program Files\Git\mingw64\etc\ssl\certs\ca-bundle.crt"
```

Other knobs: `CODEX_REAL_BIN` (bypass binary discovery), `CLAUDE_ENV_URL`
(alternate env source).

> **History:** until Sept 2026 this wrapper ran a local Python HTTP→HTTPS shim on
> `127.0.0.1:8787` to work around the above, on the mistaken assumption that
> Codex's TLS stack simply could not reach the proxy. `CODEX_CA_CERTIFICATE`
> replaces all of it, which is why Python is no longer a prerequisite. `git log`
> has the shim if you ever need it back.

## Profiles

Switch models with `codex --profile <name>` (default model: `gpt-5.6-sol`):

| Profile | Model |
|---|---|
| `gpt56-sol` | gpt-5.6-sol |
| `gpt56-terra` | gpt-5.6-terra |
| `gpt56-luna` | gpt-5.6-luna |

## Troubleshooting

- **"Connection failed: error sending request"** — Codex is verifying against
  the system trust store instead of a PEM bundle. Check what the wrapper
  resolved with `CLAUDE_DEBUG=1 codex` (it prints `ca=...`); if it says
  `<system roots>`, no bundle was found — point `CODEX_CA_CERTIFICATE` at one.
- **1Password errors / "no LITELLM_API_KEY"** — `op signin --account aproorg.1password.eu`.
  The key lives in the same 1Password item the `claude` wrapper uses.
- **Proxy error about missing `x-github-repo`** — check that
  `~/.codex/config.toml` still has the `[model_providers.litellm.env_http_headers]`
  block, and that `CLAUDE_DEBUG=1 codex` reports a sensible `repo=`.
- **Certificate errors after joining a network with TLS inspection** — set
  `SSL_CERT_FILE` to a bundle containing your corporate CA (see above).
- **Stale team config** — `rm ~/.cache/claude/env-remote.sh` (Windows:
  `Remove-Item "$env:LOCALAPPDATA\claude\env-remote.sh"`) forces a refetch of the
  shared `claude-env.sh` on next launch.
- **Something still listening on port 8787** — a leftover shim from an older
  install. `kill $(lsof -ti tcp:8787)`; nothing uses it any more.
- **Verbose debugging** — `CLAUDE_DEBUG=1 codex` (Windows: `$env:CLAUDE_DEBUG = "1"; codexstart`).
