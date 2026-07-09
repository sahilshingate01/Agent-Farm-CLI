#!/usr/bin/env bash
# usage-farm — run N isolated AI client accounts in Apple containers.
set -euo pipefail

if [ -z "${FARM_STATE:-}" ]; then
  if [ -d "$HOME/.usage-farm" ]; then
    FARM_STATE="$HOME/.usage-farm"
  elif [ -d "$HOME/.claude-farm" ]; then
    FARM_STATE="$HOME/.claude-farm"
  else
    FARM_STATE="$HOME/.usage-farm"
  fi
fi

ACCOUNTS_DIR="$FARM_STATE/accounts"
WORK="$FARM_STATE/work"
IMAGE="${FARM_IMAGE:-usage-agent}"
MEM="${FARM_MEM:-4g}"
CPUS="${FARM_CPUS:-4}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROVIDER="claude"

USAGE_PROVIDERS=("claude" "codex" "grok" "gemini")
declare -A PROVIDER_COMMAND=(
  [claude]="claude"
  [codex]="codex"
  [grok]="grok"
  [gemini]="gemini"
)
declare -A PROVIDER_CONTAINER_HOME=(
  [claude]="/root/.claude"
  [codex]="/root/.codex"
  [grok]="/root/.grok"
  [gemini]="/root/.gemini"
)

die() { echo "farm: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage-farm — N isolated AI client accounts in Apple containers

  farm build                     build/rebuild the usage-agent image
  farm new <acct>...             create + start account container(s)   (any names, any number)
  farm login <acct> [provider]   interactive auth for provider (default: claude)
  farm up [acct...]              start all (or named) account containers
  farm down [acct...]            stop all (or named)
  farm ls                        accounts, running state, auth state, email
  farm rename <old> <new>        rename an account (auth preserved)
  farm clone <url> [name]        bare-clone a repo into the shared farm
  farm wt <repo> <acct> [br]     per-account worktree on that repo
  farm run <provider> <acct> [dir]
                                run a provider client in acct's container (dir under work/)
  farm claude <acct> [dir]       run claude in acct's container (dir under work/)
  farm codex <acct> [dir]        run codex in acct's container (dir under work/)
  farm grok <acct> [dir]         run grok in acct's container (dir under work/)
  farm gemini <acct> [dir]       run gemini in acct's container (dir under work/)
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
  command -v container >/dev/null 2>&1 \
    || die "Apple 'container' CLI not found — needs macOS 26+ on Apple Silicon"
  container system status >/dev/null 2>&1 && return 0
  echo "farm: container system not running — starting it" >&2
  container system start || die "could not start container system — try: container system start"
  for _ in 1 2 3 4 5; do
    container system status >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "container system did not come up — try: container system start"
}

provider_for() {
  local provider="${1:-$DEFAULT_PROVIDER}"
  echo "${provider,,}"
}

provider_command() {
  local provider="$1"
  echo "${PROVIDER_COMMAND[$provider]:-$provider}"
}

provider_is_known() {
  local provider="$1"
  for p in "${USAGE_PROVIDERS[@]}"; do
    if [ "$p" = "$provider" ]; then
      return 0
    fi
  done
  return 1
}

provider_container_home() {
  local provider="$1"
  echo "${PROVIDER_CONTAINER_HOME[$provider]:-/root/.$provider}"
}

provider_host_home() {
  local acct="$1"
  local provider="$2"
  if [ "$provider" = "claude" ]; then
    echo "$ACCOUNTS_DIR/$acct/claude-home"
  else
    echo "$ACCOUNTS_DIR/$acct/$provider-home"
  fi
}

cname() { echo "usage-$1"; }
legacy_cname() { echo "claude-$1"; }

cname_for_account() {
  local acct="$1"
  local new old
  new="$(cname "$acct")"
  old="$(legacy_cname "$acct")"
  if container list -a 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$new"; then
    echo "$new"
  elif container list -a 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$old"; then
    echo "$old"
  else
    echo "$new"
  fi
}

running() {
  local acct="$1"
  local name
  name="$(cname_for_account "$acct")"
  container list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$name"
}

container_exists() {
  local acct="$1"
  local name
  name="$(cname_for_account "$acct")"
  container list -a 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$name"
}

known_accounts() {
  [ -d "$ACCOUNTS_DIR" ] || return 0
  find "$ACCOUNTS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

ensure_provider_dirs() {
  local acct="$1"
  mkdir -p "$ACCOUNTS_DIR/$acct"
  for provider in "${USAGE_PROVIDERS[@]}"; do
    mkdir -p "$(provider_host_home "$acct" "$provider")"
  done
}

start_one() {
  local acct="$1"
  mkdir -p "$WORK"
  ensure_provider_dirs "$acct"
  if running "$acct"; then
    echo "farm: $acct already running"
    return 0
  fi
  if container_exists "$acct"; then
    container delete "$(cname_for_account "$acct")" >/dev/null 2>&1 || true
  fi

  local -a mount_args=()
  for provider in "${USAGE_PROVIDERS[@]}"; do
    mount_args+=( -v "$(provider_host_home "$acct" "$provider"):$(provider_container_home "$provider")" )
  done
  shopt -s nullglob
  for home in "$ACCOUNTS_DIR/$acct"/*-home; do
    [ -d "$home" ] || continue
    provider="$(basename "$home")"
    provider="${provider%-home}"
    [ "$provider" = "claude" ] && continue
    skip=false
    for p in "${USAGE_PROVIDERS[@]}"; do
      [ "$p" = "$provider" ] && skip=true && break
    done
    $skip || mount_args+=( -v "$home:/root/.$provider" )
  done
  shopt -u nullglob

  container run -d \
    --name "$(cname "$acct")" \
    -m "$MEM" -c "$CPUS" \
    -v "$WORK:$WORK" \
    "${mount_args[@]}" \
    -w "$WORK" \
    "$IMAGE" sleep infinity >/dev/null
  echo "farm: started $acct  (mem=$MEM cpus=$CPUS)"
}

run_provider() {
  local provider acct sub cmd_name container_name
  provider="$(provider_for "$1")"
  acct="$2"
  sub="${3:-}"
  cmd_name="$(provider_command "$provider")"
  mkdir -p "$(provider_host_home "$acct" "$provider")"

  [ -n "$acct" ] || die "usage: farm <provider> <acct> [dir-under-work]"
  if ! running "$acct" || ! provider_is_known "$provider"; then
    if running "$acct"; then
      container stop "$(cname_for_account "$acct")" >/dev/null 2>&1 || true
      container delete "$(cname_for_account "$acct")" >/dev/null 2>&1 || true
    fi
    start_one "$acct"
  fi
  container_name="$(cname_for_account "$acct")"

  if ! container exec "$container_name" sh -lc "command -v '$cmd_name' >/dev/null 2>&1"; then
    echo "farm: missing client '$cmd_name' in container image '$IMAGE'." >&2
    echo "farm: set FARM_IMAGE to an image that provides '$cmd_name', or install it in this image." >&2
    exit 1
  fi

  if [ "$provider" = "claude" ]; then
    echo "farm: opening $provider in $acct — for Claude use /login to authenticate"
  fi

  container exec -it "$container_name" sh -c 'cd "$1" && exec "$2"' sh "$WORK/$sub" "$cmd_name"
}

cmd="${1:-help}"; shift || true

# any command that touches the container CLI needs the system service up
case "$cmd" in
  build|new|up|down|login|run|claude|codex|grok|gemini|shell|ls|status|rename|rm)
    ensure_system
    ;;
esac

case "$cmd" in
  build)
    container build -t "$IMAGE" "$REPO_DIR"
    ;;

  new)
    [ $# -ge 1 ] || die "usage: farm new <acct> [<acct>...]"
    for a in "$@"; do start_one "$a"; done
    echo "farm: now run 'farm login <acct> [provider]' to authenticate each account"
    echo "farm: then 'farm setup <acct>' to install skills / MCP (Vercel skills CLI)"
    ;;

  up)
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
      running "$a" && { container stop "$(cname_for_account "$a")" >/dev/null; echo "farm: stopped $a"; } || true
    done
    ;;

  login)
    [ $# -eq 1 ] || [ $# -eq 2 ] || die "usage: farm login <acct> [provider]"
    acct="$1"
    provider="$(provider_for "${2:-$DEFAULT_PROVIDER}")"
    run_provider "$provider" "$acct"
    ;;

  run)
    [ $# -ge 2 ] || die "usage: farm run <provider> <acct> [dir-under-work]"
    run_provider "$1" "$2" "${3:-}"
    ;;

  claude|codex|grok|gemini)
    [ $# -ge 1 ] || die "usage: farm $cmd <acct> [dir-under-work]"
    run_provider "$cmd" "$1" "${2:-}"
    ;;

  shell)
    [ $# -eq 1 ] || die "usage: farm shell <acct>"
    running "$1" || start_one "$1"
    container exec -it "$(cname_for_account "$1")" bash
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
    container stop "$(cname_for_account "$1")" >/dev/null 2>&1 || true
    container delete "$(cname_for_account "$1")" >/dev/null 2>&1 || true
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
    echo "farm: worktree ready — run: farm run claude $acct wt-$repo-$acct"
    ;;

  rm)
    [ $# -ge 1 ] || die "usage: farm rm <acct> [<acct>...] (container only; state kept)"
    for a in "$@"; do
      container stop "$(cname_for_account "$a")" >/dev/null 2>&1 || true
      container delete "$(cname_for_account "$a")" >/dev/null 2>&1 || true
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
