# claude-farm

**N isolated Claude Code accounts on one Mac.**  
CLI: `farm`

Each account is a lightweight Linux VM (Apple’s native `container` CLI — macOS 26+, Apple Silicon), logged into its **own** Claude OAuth. No shared Keychain, no credential collisions, no agents touching your real home directory.

![claude-farm — isolated Claude Code VMs on a Mac host](docs/hero.jpg)

---

## How it fits together

![Architecture: host farm CLI, per-account VMs, shared work](docs/architecture.svg)

| Layer | What | Where |
|---|---|---|
| **CLI / tooling** | `farm` | this repo — **in git** |
| **Per-account state** | OAuth, skills, agents, MCP, settings | `~/.claude-farm/accounts/<name>/claude-home` — **never in git** |
| **Shared workspace** | bare repos + worktrees | `~/.claude-farm/work` — mounted at the **same absolute path** on host and in every VM |

```
┌─ Host (macOS) ─────────────────────────────────────────────┐
│  farm  ·  farm setup  ·  farm equip                        │
│  ~/.claude-farm/accounts/<acct>/claude-home  ──┐           │
│  ~/.claude-farm/work  ──────────────────────┐  │           │
└─────────────────────────────────────────────│──│───────────┘
                                              │  │
         ┌────────────────────────────────────┘  │
         ▼                                       ▼
   shared work/                    /root/.claude  (private)
   (identical path)                per-account kit
         ▲
   ┌─────┴──────┬──────────────┬──────────────┐
   │  VM hello  │  VM sahil    │  VM acct N   │
   │  own OAuth │  own OAuth   │  own OAuth   │
   └────────────┴──────────────┴──────────────┘
```

Isolation is structural: each VM has no macOS Keychain, so credentials stay per-account files on the host volume.

---

## Requirements

- macOS 26+ on Apple Silicon, with Apple's [`container`](https://github.com/apple/container) CLI
- `jq` and `python3` on the host
- Node.js on the host — only for `farm setup` / `farm equip` (the Vercel skills CLI runs via `npx`)
- `fzf` (optional) — nicer multi-select in `farm setup`

---

## Install

```bash
# one-time image
./farm.sh build

# shell aliases (defines `farm` + per-account shortcuts)
echo 'source /path/to/claude-farm/farm-aliases.sh' >> ~/.zshrc
```

Aliases from `farm-aliases.sh`:

| Alias | Runs |
|---|---|
| `farm` | main CLI |
| `claude-farm` | synonym for `farm` |
| `claude-<acct>` | `farm claude <acct>` — generated automatically for every existing account |

---

## Quick start

```bash
farm build                      # one-time image
farm new hello sahil            # any names, any count
farm login hello                # /login in the VM; open URL on Mac, paste code
farm setup hello                # skills + MCP wizard (Vercel skills CLI)
farm clone git@github.com:you/repo.git
farm wt repo hello              # worktree + branch for that account
farm claude hello wt-repo-hello
```

---

## Skills, MCP, and profiles

Containers start with a **blank** Claude home (no host plugins/hooks). Equip them deliberately:

```bash
farm setup hello                      # interactive wizard
farm equip hello --profile coding     # non-interactive
farm equip hello --list               # inventory
farm profiles                         # bundled profiles + MCP catalog
```

### `farm setup` flow

1. **Baseline profile** — `blank` · `minimal` · `coding` · `frontend` · `custom`
2. **Vercel skills CLI** — installs with  
   `CLAUDE_CONFIG_DIR=~/.claude-farm/accounts/<acct>/claude-home`  
   so packages land on the mounted volume and appear inside the container
3. **Host picks** — multi-select (fzf) of skills / agents / commands from `~/.claude` — **copied**, not symlinked (host skill trees often live under `~/Library/...`, invisible in Linux VMs)
4. **MCP catalog** — container-safe servers only (`context7`, `playwright`, `filesystem`)

| Bundled profile | Intent |
|---|---|
| `minimal` | `find-skills` only |
| `coding` | `vercel-labs/agent-skills` + common host toolkit + context7 |
| `frontend` | UI-oriented skills + playwright |

Profiles: `profiles/*.json`  
MCP entries: `mcp-catalog/*.json`  
Applied stamp: `~/.claude-farm/accounts/<acct>/profile.json`

**Not copied:** host hooks (macOS paths / binaries break in the VM).  
**Not auto-enabled:** host-only MCP (e.g. Tolaria under `/Applications`).

```
farm setup / equip
        │
        ├─► npx skills add …   (CLAUDE_CONFIG_DIR = account home)
        ├─► copy host skills / agents / commands
        └─► merge mcp-catalog → account .mcp.json
                    │
                    ▼
     ~/.claude-farm/accounts/<acct>/claude-home/
         skills/  agents/  commands/  .mcp.json  profile.json
                    │
                    ▼  (bind-mounted)
              /root/.claude  inside the VM
```

---

## Commands

```
farm build                     build/rebuild the claude-agent image
farm new <acct>...             create + start account container(s)
farm login <acct>              interactive claude for first /login
farm up [acct...]              start all (or named) account containers
farm down [acct...]            stop all (or named)
farm ls                        accounts, running state, auth, email
farm rename <old> <new>        rename account (auth preserved)
farm clone <url> [name]        bare-clone into shared work/
farm wt <repo> <acct> [br]     per-account worktree
farm claude <acct> [dir]       run claude in that container
farm shell <acct>              bash inside the container
farm rm <acct>...              delete container (state kept)

farm setup <acct>              interactive skills / MCP wizard
farm equip <acct> --profile X  apply profile non-interactively
farm equip <acct> --list       show installed kit
farm profiles [list|show name] bundled profiles + MCP catalog
```

Env overrides: `FARM_STATE` · `FARM_IMAGE` · `FARM_MEM` (default `4g`) · `FARM_CPUS` (default `4`) · `HOST_CLAUDE`

---

## Scaling to N

Nothing is hardcoded to a fixed account count:

```bash
farm new acct5 acct6 review-bot
```

Practical ceiling is RAM. Each container is a VM capped at `FARM_MEM` (default 4g, allocated on demand). Rule of thumb:

**comfortable N ≈ free RAM ÷ 3–4 GB** for actively working agents.

Idle containers cost little CPU. Stop what you are not using: `farm down acct3`.

---

## Notes

- **Auth survives rebuilds** — it lives on the host under `~/.claude-farm/accounts/<name>/claude-home`. Back that up carefully; it holds OAuth tokens.
- **GitHub from a container:** `farm shell <acct>` → `gh auth login`, and set `git config --global user.email` per account.
- **Agent separation** inside the shared farm is by convention (one worktree per account). For hard isolation, mount a per-account work dir instead of the shared `work/`.
- **Image contents:** Node 22, `claude`, `git`, `gh`, `rg`, `jq` — see `Dockerfile`.

---

## Layout (git vs state)

| Path | Purpose | In git? |
|---|---|---|
| `farm.sh` · `lib/equip.sh` | CLI | yes |
| `profiles/` · `mcp-catalog/` | equip defaults | yes |
| `docs/architecture.svg` · `docs/hero.jpg` | diagrams | yes |
| `farm-aliases.sh` | shell aliases | yes |
| `~/.claude-farm/accounts/*` | credentials + kit | **no** |
| `~/.claude-farm/work/` | shared workspace | **no** |

---

## License

[MIT](LICENSE)
