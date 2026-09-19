#!/bin/zsh
# macos-hdmi-audio-fix をビルドしてインストールし、常駐エージェントを登録する。
#
#   ./install.sh              既定の場所にインストール
#   BIN_DIR=~/.local/bin ./install.sh   CLI の設置先を変える
#
set -eu

REPO=${0:a:h}
APP_NAME="HDMI Audio Fix"
BUNDLE_ID="io.github.macos-hdmi-audio-fix"
LABEL="$BUNDLE_ID.watch"
APP_DIR="$HOME/Applications/$APP_NAME.app"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/hdmi-audio-fix.log"

command -v swiftc >/dev/null || {
  echo "swiftc が見つかりません。Xcode Command Line Tools を入れてください:" >&2
  echo "  xcode-select --install" >&2
  exit 1
}

echo "==> アプリバンドルをビルド"
mkdir -p "$APP_DIR/Contents/MacOS" "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>HDMIAudioFix</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>         <string>モニター音声 自動復旧</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>LSUIElement</key>                 <true/>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>HDMI / DisplayPort でつないだモニターの音声が、macOS の不具合で再生できなくなる問題を自動で修復します。起動時・スリープ復帰時・再生失敗の検知時に、音声デバイスのサンプルレートを一瞬切り替えて I/O を立て直します。</string>
</dict>
</plist>
EOF
swiftc -O -o "$APP_DIR/Contents/MacOS/HDMIAudioFix" "$REPO/src/AudioFix.swift"

# 署名が無いとシステム設定での表示名が安定しないため ad-hoc 署名する
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR" >/dev/null 2>&1 || true

echo "==> コマンドを $BIN_DIR に設置"
ln -sfn "$APP_DIR/Contents/MacOS/HDMIAudioFix" "$BIN_DIR/audio-fix"
install -m 0755 "$REPO/bin/audio-revive" "$BIN_DIR/audio-revive"
install -m 0755 "$REPO/bin/audio-last"   "$BIN_DIR/audio-last"

echo "==> 常駐エージェントを登録"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- HDMI / DisplayPort モニターの音声が出なくなる macOS の不具合を自動修復する。
         https://github.com/ShoutaWATANABE/macos-hdmi-audio-fix -->
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DIR/Contents/MacOS/HDMIAudioFix</string>
        <string>watch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "インストールが完了しました。"
echo "  アプリ   : $APP_DIR"
echo "  コマンド : $BIN_DIR/{audio-fix,audio-revive,audio-last}"
echo "  ログ     : $LOG"
echo
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "注意: $BIN_DIR が PATH にありません。シェルの設定に追加してください。"; echo ;;
esac
"$BIN_DIR/audio-fix" status
