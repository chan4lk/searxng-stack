#!/bin/bash
# llama-swap on the Mac Studio (see config.yaml). Run on the Studio from ~/searxng-stack/llama-swap:
#   ./llama-swap.sh install   # download the pinned release to ~/llama-swap, copy config, (re)load the LaunchAgent
#   ./llama-swap.sh run       # foreground (what the LaunchAgent runs)
#   ./llama-swap.sh status|logs|restart|validate
set -e
VERSION=268
SHA256=373a1bb5014180e44a91a5e7a7aa24f1ba18b5dfd9622779f7aa234bd33eec86   # llama-swap_268_darwin_arm64.tar.gz
DIR=~/llama-swap
LABEL=com.searxng-stack.llama-swap
PLIST=~/Library/LaunchAgents/$LABEL.plist
LOG=~/Library/Logs/llama-swap.log
LISTEN=100.101.212.33:8100
HERE=$(cd "$(dirname "$0")" && pwd)

case $1 in
  run)
    export STUDIO_API_KEY=$(cat ~/.sushi/api-key) PATH=/opt/homebrew/bin:$PATH
    exec "$DIR/llama-swap" -config "$DIR/config.yaml" -listen "$LISTEN" -watch-config ;;
  validate)
    STUDIO_API_KEY=x "$DIR/llama-swap" -config "${2:-$HERE/config.yaml}" -validate ;;
  install)
    mkdir -p "$DIR"
    if ! "$DIR/llama-swap" -version 2>/dev/null | grep -q "v$VERSION "; then
      curl -fsSL -o /tmp/llama-swap.tgz "https://github.com/mostlygeek/llama-swap/releases/download/v$VERSION/llama-swap_${VERSION}_darwin_arm64.tar.gz"
      echo "$SHA256  /tmp/llama-swap.tgz" | shasum -a 256 -c -
      tar xzf /tmp/llama-swap.tgz -C "$DIR" llama-swap && rm /tmp/llama-swap.tgz
    fi
    "$0" validate
    cp "$HERE/config.yaml" "$DIR/config.yaml"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$HERE/llama-swap.sh</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "llama-swap v$VERSION on http://$LISTEN (UI /ui)" ;;
  restart) launchctl kickstart -k "gui/$(id -u)/$LABEL" ;;
  status)  launchctl print "gui/$(id -u)/$LABEL" | grep -E "state|pid" | head -2
           curl -s -m 3 -H "Authorization: Bearer $(cat ~/.sushi/api-key)" "http://$LISTEN/running" ;;
  logs)    tail -n "${2:-50}" "$LOG" ;;
  *) echo "usage: $0 install|run|validate|status|logs|restart" >&2; exit 2 ;;
esac
