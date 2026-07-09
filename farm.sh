#!/usr/bin/env bash
# claude-farm — run N isolated Claude Code instances in Apple containers,
# each authed as its own Claude account.
#
# State lives OUTSIDE this repo (credentials!):
#   ~/.claude-farm/accounts/<name>/claude-home   -> /root/.claude in that container
#   ~/.claude-farm/work                          -> shared farm workspace, mounted
#                                                   at the SAME path in every container
set -euo pipefail

FARM_STATE="${FARM_STATE:-$HOME/.claude-farm}"
ACCOUNTS_DIR="$FARM_STATE/accounts"
WORK="$FARM_STATE/work"
IMAGE="${FARM_IMAGE:-claude-agent}"
MEM="${FARM_MEM:-4g}"
CPUS="${FARM_CPUS:-4}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "farm: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
claude-farm — N isolated Claude Code accounts in Apple containers

  farm build                     build/rebuild the claude-agent image
  farm new <acct>...             create + start account container(s)   (any names, any number)
  farm login <acct>              interactive claude for first /login
  farm up [acct...]              start all (or named) account containers
  farm down [acct...]            stop all (or named)
  farm ls                        accounts, running state, auth state, email
  farm rename <old> <new>        rename an account (auth preserved)
  farm clone <url> [name]        bare-clone a repo into the shared farm
  farm wt <repo> <acct> [br]     per-account worktree on that repo
  farm claude <acct> [dir]       run claude in acct's container (dir under work/)
  farm shell <acct>              bash inside acct's container
  farm rm <acct>...              delete container (auth/state preserved)

  Skills / MCP (per-account home, not host ~/.claude):
  farm setup <acct>              interactive wizard — Vercel skills, host picks, MCP
  farm equip <acct> --profile X  apply a bundled/custom profile non-interactively
  farm equip <acct> --list       show skills/agents/commands/MCP on an account
  farm profiles                  list bundled profiles + MCP catalog
  farm profiles show <name>      print a profile JSON

env overrides: FARM_STATE FARM_IMAGE FARM_MEM (4g) FARM_CPUS (4) HOST_CLAUDE
EOF
}

# shellcheck source=lib/equip.sh
source "$REPO_DIR/lib/equip.sh"

ensure_system() {
  container system status >/dev/null 2>&1 || container system start
}

cname() { echo "claude-$1"; }

known_accounts() {
  [ -d "$ACCOUNTS_DIR" ] || return 0
  find "$ACCOUNTS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

running() {
  container list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$(cname "$1")"
}

container_exists() {
  container list -a 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$(cname "$1")"
}

start_one() {
  local acct="$1"
  mkdir -p "$ACCOUNTS_DIR/$acct/claude-home" "$WORK"
  if running "$acct"; then
    echo "farm: $acct already running"
    return 0
  fi
  # a stopped container would make `container run` fail on the name;
  # recreate so every start picks up the current image and mem/cpu settings
  if container_exists "$acct"; then
    container delete "$(cname "$acct")" >/dev/null 2>&1 || true
  fi
  container run -d \
    --name "$(cname "$acct")" \
    -m "$MEM" -c "$CPUS" \
    -v "$ACCOUNTS_DIR/$acct/claude-home:/root/.claude" \
    -v "$WORK:$WORK" \
    -w "$WORK" \
    "$IMAGE" sleep infinity >/dev/null
  echo "farm: started $acct  (mem=$MEM cpus=$CPUS)"
}

cmd="${1:-help}"; shift || true

case "$cmd" in
  build)
    ensure_system
    container build -t "$IMAGE" "$REPO_DIR"
    ;;

  new)
    [ $# -ge 1 ] || die "usage: farm new <acct> [<acct>...]"
    ensure_system
    for a in "$@"; do start_one "$a"; done
    echo "farm: now run 'farm login <acct>' to authenticate each account"
    echo "farm: then 'farm setup <acct>' to install skills / MCP (Vercel skills CLI)"
    ;;

  up)
    ensure_system
    accts=("$@")
    if [ ${#accts[@]} -eq 0 ]; then
      while IFS= read -r a; do accts+=("$a"); done < <(known_accounts)
    fi
    [ ${#accts[@]} -gt 0 ] || die "no accounts yet — create one with: farm new acct1"
    for a in "${accts[@]}"; do start_one "$a"; done
    ;;

  down)
    accts=("$@")
    if [ ${#accts[@]} -eq 0 ]; then
      while IFS= read -r a; do accts+=("$a"); done < <(known_accounts)
    fi
    [ ${#accts[@]} -gt 0 ] || { echo "farm: no accounts"; exit 0; }
    for a in "${accts[@]}"; do
      running "$a" && { container stop "$(cname "$a")" >/dev/null; echo "farm: stopped $a"; } || true
    done
    ;;

  login)
    [ $# -eq 1 ] || die "usage: farm login <acct>"
    running "$1" || start_one "$1"
    echo "farm: opening claude in $1 — use /login, open the URL on your Mac, paste the code"
    container exec -it "$(cname "$1")" claude
    ;;

  claude)
    [ $# -ge 1 ] || die "usage: farm claude <acct> [dir-under-work]"
    acct="$1"; sub="${2:-}"
    running "$acct" || start_one "$acct"
    container exec -it "$(cname "$acct")" sh -c 'cd "$1" && exec claude' sh "$WORK/$sub"
    ;;

  shell)
    [ $# -eq 1 ] || die "usage: farm shell <acct>"
    running "$1" || start_one "$1"
    container exec -it "$(cname "$1")" bash
    ;;

  ls|status)
    printf '%-12s %-9s %-7s %s\n' ACCOUNT RUNNING AUTHED EMAIL
    for a in $(known_accounts); do
      r=no; running "$a" && r=yes
      auth=no
      if [ -f "$ACCOUNTS_DIR/$a/claude-home/.credentials.json" ] || [ -f "$ACCOUNTS_DIR/$a/claude-home/credentials.json" ]; then
        auth=yes
      fi
      email=$(jq -r '.oauthAccount.emailAddress // empty' "$ACCOUNTS_DIR/$a/claude-home/.claude.json" 2>/dev/null || true)
      printf '%-12s %-9s %-7s %s\n' "$a" "$r" "$auth" "${email:--}"
    done
    ;;

  rename)
    [ $# -eq 2 ] || die "usage: farm rename <old> <new>"
    [ -d "$ACCOUNTS_DIR/$1" ] || die "no account '$1'"
    [ -e "$ACCOUNTS_DIR/$2" ] && die "account '$2' already exists"
    container stop "$(cname "$1")" >/dev/null 2>&1 || true
    container delete "$(cname "$1")" >/dev/null 2>&1 || true
    mv "$ACCOUNTS_DIR/$1" "$ACCOUNTS_DIR/$2"
    start_one "$2"
    echo "farm: renamed $1 -> $2 (auth preserved)"
    ;;

  clone)
    [ $# -ge 1 ] || die "usage: farm clone <git-url-or-path> [name]"
    mkdir -p "$WORK"
    name="${2:-$(basename "$1" .git)}"
    git clone --bare "$1" "$WORK/$name.git"
    echo "farm: bare repo at $WORK/$name.git — add worktrees with: farm wt $name <acct>"
    ;;

  wt)
    [ $# -ge 2 ] || die "usage: farm wt <repo> <acct> [branch]"
    repo="$1"; acct="$2"; branch="${3:-$acct/work}"
    [ -d "$WORK/$repo.git" ] || die "no bare repo $WORK/$repo.git — run: farm clone <url> $repo"
    git -C "$WORK/$repo.git" worktree add "$WORK/wt-$repo-$acct" -b "$branch" \
      || git -C "$WORK/$repo.git" worktree add "$WORK/wt-$repo-$acct" "$branch"
    echo "farm: worktree ready — run: farm claude $acct wt-$repo-$acct"
    ;;

  rm)
    [ $# -ge 1 ] || die "usage: farm rm <acct> [<acct>...] (container only; state kept)"
    for a in "$@"; do
      container stop "$(cname "$a")" >/dev/null 2>&1 || true
      container delete "$(cname "$a")" >/dev/null 2>&1 || true
      echo "farm: removed container for $a (state kept at $ACCOUNTS_DIR/$a)"
    done
    ;;

  setup)
    cmd_setup "$@"
    ;;

  equip)
    cmd_equip "$@"
    ;;

  profiles)
    cmd_profiles "$@"
    ;;

  help|--help|-h)
    usage
    ;;

  *)
    usage >&2
    die "unknown command: $cmd"
    ;;
esac
