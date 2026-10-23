#!/bin/zsh
# Builds MicBridgeSender.app (for the MacBook Air) and MicBridgeReceiver.app (for the Mac mini)
# into ./build. They are small background apps (no Dock icon); bundling them as apps lets
# macOS ask for Microphone / Local Network permission properly.
set -e
cd "${0:A:h}"
mkdir -p build

make_app() {
  local name=$1 src=$2 exe=$3 bundle=build/$1.app
  rm -rf $bundle
  mkdir -p $bundle/Contents/MacOS
  cat > $bundle/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.micbridge.$exe</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>MicBridge streams this Mac's microphone to your other Mac.</string>
  <key>NSLocalNetworkUsageDescription</key><string>MicBridge connects your two Macs over the local network.</string>
  <key>NSBonjourServices</key><array><string>_micbridge._tcp</string></array>
</dict></plist>
EOF
  # Universal binary so it also runs on an Intel MacBook Air.
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos14.2 Sources/$src -o build/$exe-$arch
  done
  lipo -create build/$exe-arm64 build/$exe-x86_64 -output $bundle/Contents/MacOS/$exe
  rm build/$exe-arm64 build/$exe-x86_64
  codesign --force --sign - $bundle
  echo "built $bundle"
}

make_app MicBridgeSender   Sender.swift   micbridge-sender
make_app MicBridgeReceiver Receiver.swift micbridge-receiver
