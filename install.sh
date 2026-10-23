#!/bin/zsh
# Installs one side of MicBridge as a login item that starts automatically and restarts if it crashes.
#   ./install.sh sender     on the MacBook Air
#   ./install.sh receiver   on the Mac mini   (extra receiver options can follow, e.g. --host 192.168.1.20)
#   ./install.sh uninstall  on either machine
set -e
cd "${0:A:h}"
role=$1; shift || true

remove() {
  for r in sender receiver; do
    launchctl bootout gui/$UID/local.micbridge.$r 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/local.micbridge.$r.plist
  done
  rm -rf ~/Applications/MicBridgeSender.app ~/Applications/MicBridgeReceiver.app
}

case $role in
  sender)   app=MicBridgeSender;   exe=micbridge-sender ;;
  receiver) app=MicBridgeReceiver; exe=micbridge-receiver ;;
  uninstall) remove; echo "MicBridge removed."; exit 0 ;;
  *) echo "usage: $0 sender|receiver|uninstall [receiver options]"; exit 2 ;;
esac

[[ -d build/$app.app ]] || ./build.sh
remove
mkdir -p ~/Applications ~/Library/LaunchAgents ~/Library/Logs
cp -R build/$app.app ~/Applications/

extra=""
for a in "$@"; do extra+="    <string>$a</string>"$'\n'; done
plist=~/Library/LaunchAgents/local.micbridge.$role.plist
cat > $plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.micbridge.$role</string>
  <key>ProgramArguments</key><array>
    <string>$HOME/Applications/$app.app/Contents/MacOS/$exe</string>
$extra  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/micbridge-$role.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/micbridge-$role.log</string>
</dict></plist>
EOF
launchctl bootstrap gui/$UID $plist
echo "Installed and started. Log: ~/Library/Logs/micbridge-$role.log"
