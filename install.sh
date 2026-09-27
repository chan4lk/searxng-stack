#!/usr/bin/env bash
# Install the client side of the setup on this machine: Claude Code and
# DeepSeek Harness (dsh) wired to a Splash LLM server and this SearXNG stack
# over Tailscale, plus a Claude Code skill for managing the server.
#
#   cp install.env.example install.env && $EDITOR install.env
#   ./install.sh --dry-run     show what would be written, change nothing
#   ./install.sh               install (existing files that differ are backed up)
#
# Installs:
#   ~/.claude/splash-settings.json                      Claude Code -> Splash
#   ~/.claude/skills/<SERVER_NAME>/                     server-management skill
#   ~/.dsh/splash.settings.yaml, ~/.dsh/splash.patch.yml dsh -> Splash + SearXNG
#   ~/.dsh/plugins/{searxng-search,cwd-workspace,image-generate,studio-guard}.mjs  dsh plugins
#   aliases claude-splash / dsh-splash in ~/.zshrc
set -euo pipefail

cd "$(dirname "$0")"
DRY_RUN=0
[[ ${1:-} == --dry-run ]] && DRY_RUN=1
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

[[ -f install.env ]] || { echo "install.env missing: cp install.env.example install.env and fill it in" >&2; exit 1; }
# shellcheck disable=SC1091
source install.env

VARS=(SERVER_IP SERVER_NAME TAILNET SERVER_USER TAILNET_ACCOUNT SERVER_SPECS SPLASH_MODEL)
for v in "${VARS[@]}"; do
  val="${!v:-}"
  [[ -n $val ]] || { echo "install.env: $v is empty" >&2; exit 1; }
  [[ $val == *x.y.z* || $val == *XXXX* || $val == your-* ]] && { echo "install.env: $v still has its example value ($val)" >&2; exit 1; }
done
HOME_DIR="$HOME"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Escape a value for the replacement side of a sed s|||.
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

render() {
  sed -e "s|__SERVER_IP__|$(esc "$SERVER_IP")|g" \
      -e "s|__SERVER_NAME__|$(esc "$SERVER_NAME")|g" \
      -e "s|__TAILNET__|$(esc "$TAILNET")|g" \
      -e "s|__SERVER_USER__|$(esc "$SERVER_USER")|g" \
      -e "s|__TAILNET_ACCOUNT__|$(esc "$TAILNET_ACCOUNT")|g" \
      -e "s|__SERVER_SPECS__|$(esc "$SERVER_SPECS")|g" \
      -e "s|__SPLASH_MODEL__|$(esc "$SPLASH_MODEL")|g" \
      -e "s|__HOME__|$(esc "$HOME_DIR")|g" "$1"
}

# install <source> <dest> [render]: write dest, backing up a differing original.
install_file() {
  local src="$1" dest="$2" mode="${3:-copy}" tmp
  tmp="$(mktemp)"
  if [[ $mode == render ]]; then render "$src" > "$tmp"; else cp "$src" "$tmp"; fi
  if grep -q '__[A-Z_]*__' "$tmp"; then
    echo "unrendered placeholder in $dest:" >&2; grep -n '__[A-Z_]*__' "$tmp" >&2; rm -f "$tmp"; exit 1
  fi
  if [[ -f $dest ]] && cmp -s "$tmp" "$dest"; then
    echo "  unchanged  $dest"; rm -f "$tmp"; return
  fi
  if (( DRY_RUN )); then
    if [[ -f $dest ]]; then echo "  would update $dest"; { diff -u "$dest" "$tmp" || true; } | sed "s/^/      /" | head -40
    else echo "  would create $dest"; fi
    rm -f "$tmp"; return
  fi
  mkdir -p "$(dirname "$dest")"
  if [[ -f $dest ]]; then cp -p "$dest" "$dest.bak-$STAMP"; echo "  updated    $dest  (backup: $(basename "$dest").bak-$STAMP)"
  else echo "  created    $dest"; fi
  mv "$tmp" "$dest"
  [[ $dest == *.sh ]] && chmod +x "$dest"
  return 0
}

add_alias() {
  local name="$1" line="$2" rc="$HOME/.zshrc"
  if grep -q "^alias ${name}=" "$rc" 2>/dev/null; then
    if grep -qxF "$line" "$rc"; then echo "  unchanged  alias $name"; return; fi
    if (( DRY_RUN )); then echo "  would update alias $name"; return; fi
    cp -p "$rc" "$rc.bak-$STAMP"
    local tmp; tmp="$(mktemp)"
    awk -v n="alias ${name}=" -v l="$line" 'index($0, n) == 1 { print l; next } { print }' "$rc" > "$tmp" && mv "$tmp" "$rc"
    echo "  updated    alias $name  (backup: .zshrc.bak-$STAMP)"
  else
    if (( DRY_RUN )); then echo "  would add alias $name"; return; fi
    printf '%s\n' "$line" >> "$rc"; echo "  added      alias $name"
  fi
}

SKILL_DIR="$HOME/.claude/skills/$SERVER_NAME"
SEARXNG_URL="http://${SERVER_NAME}.${TAILNET}:8889"
IMAGE_SERVER_URL="http://${SERVER_NAME}.${TAILNET}:8890"

(( DRY_RUN )) && echo "Dry run: nothing will be written."
echo "Claude Code"
install_file clients/claude-code/splash-settings.json.tmpl "$HOME/.claude/splash-settings.json" render
install_file skills/mac-studio/SKILL.md.tmpl              "$SKILL_DIR/SKILL.md" render
install_file skills/mac-studio/scripts/studio.sh.tmpl     "$SKILL_DIR/scripts/studio.sh" render
echo "DeepSeek Harness"
install_file clients/dsh/splash.settings.yaml.tmpl "$HOME/.dsh/splash.settings.yaml" render
install_file clients/dsh/splash.patch.yml.tmpl     "$HOME/.dsh/splash.patch.yml" render
install_file clients/dsh/searxng-search.mjs        "$HOME/.dsh/plugins/searxng-search.mjs"
install_file clients/dsh/cwd-workspace.mjs         "$HOME/.dsh/plugins/cwd-workspace.mjs"
install_file clients/dsh/image-generate.mjs        "$HOME/.dsh/plugins/image-generate.mjs"
install_file clients/dsh/studio-guard.mjs          "$HOME/.dsh/plugins/studio-guard.mjs"
echo "Shell aliases (~/.zshrc)"
add_alias claude-splash "alias claude-splash='claude --settings ~/.claude/splash-settings.json'"
add_alias dsh-splash "alias dsh-splash='SPLASH_API_KEY=splash-local SEARXNG_URL=${SEARXNG_URL} IMAGE_SERVER_URL=${IMAGE_SERVER_URL} dsh --patch ~/.dsh/splash.patch.yml'"

(( DRY_RUN )) && exit 0
echo
echo "Done. Open a new shell (or: source ~/.zshrc), then try:"
echo "  bash $SKILL_DIR/scripts/studio.sh health"
echo "  claude-splash            dsh-splash --profile web"
