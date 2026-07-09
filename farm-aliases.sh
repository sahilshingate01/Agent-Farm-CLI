# claude-farm aliases — source from ~/.zshrc or ~/.bashrc:
#   source /path/to/claude-farm/farm-aliases.sh

# resolve this file's directory (works when sourced from zsh or bash)
if [ -n "${ZSH_VERSION:-}" ]; then
  _farm_dir="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
  _farm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
FARM="$_farm_dir/farm.sh"
unset _farm_dir

# primary CLI
alias farm="$FARM"
# repo name synonym (optional)
alias claude-farm="$FARM"

# one-word Claude per existing account: claude-<acct>
# (append a dir under work/ to open in a worktree, e.g. `claude-hello wt-myrepo-hello`)
_farm_accounts="${FARM_STATE:-$HOME/.claude-farm}/accounts"
if [ -d "$_farm_accounts" ]; then
  while IFS= read -r _acct; do
    [ -n "$_acct" ] && alias "claude-$_acct"="$FARM claude $_acct"
  done <<EOF
$(find "$_farm_accounts" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null)
EOF
  unset _acct
fi
unset _farm_accounts
