#!/bin/zsh
# iPhone 実機にビルドしてインストールし、起動する。
# 事前: iPhone をロック解除して USB 接続 / 同じ Wi-Fi、デベロッパモード ON。
# 使い方: scripts/install-iphone.sh [device-name-or-id]   (省略時: 最初に見つかった iPhone)
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available/ {print $1; exit}')
fi
[[ -n "$DEVICE" ]] || { echo "iPhone が見つかりません。接続とロック解除を確認してください。"; exit 1; }
echo "==> device: $DEVICE"

xcodegen generate >/dev/null
xcodebuild -project Totta.xcodeproj -scheme Totta-iOS -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD" || true

APP=build/DerivedData/Build/Products/Debug-iphoneos/totta.app
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" com.koshikawa.totta.ios || true
echo "==> 初回は iPhone の 設定 > 一般 > VPNとデバイス管理 で開発者を信頼してから起動してください。"
