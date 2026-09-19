#!/bin/zsh
# macos-hdmi-audio-fix をアンインストールする。
set -eu

BUNDLE_ID="io.github.macos-hdmi-audio-fix"
LABEL="$BUNDLE_ID.watch"
APP_DIR="$HOME/Applications/HDMI Audio Fix.app"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 常駐エージェントを停止"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || echo "   (登録されていません)"
rm -f "$PLIST"

echo "==> コマンドを削除"
rm -f "$BIN_DIR/audio-fix" "$BIN_DIR/audio-revive" "$BIN_DIR/audio-last"

echo "==> アプリを削除"
rm -rf "$APP_DIR"

echo
echo "アンインストールしました。ログ（~/Library/Logs/hdmi-audio-fix.log）は残してあります。"
echo "無音になった場合は、モニターの電源を入れ直すか、"
echo "「サウンド」設定でサンプルレートを一度変えて戻せば復旧します。"
