# macos-hdmi-audio-fix

> **English summary** — On macOS 26/27, audio over HDMI/DisplayPort can stop working entirely while the
> display still shows video. The device stays enumerated and looks healthy, but CoreAudio never starts
> the I/O clock: every playback attempt waits 10 seconds and returns `0 frames`, with
> `could not establish a timeline` and `Error: 1937010544` (`'stop'`) in the unified log.
> Restarting `coreaudiod` does **not** help. Toggling the device's nominal sample rate
> (48 kHz → 44.1 kHz → 48 kHz) rebuilds the I/O context and restores audio.
> This tool runs as a LaunchAgent and applies that fix automatically at **boot**, on **wake from sleep**,
> and whenever it sees a playback failure in the log. It also ships two diagnostic commands that measure
> how many frames actually reached the device, so you can tell "never played" from "played but cut off".
> Device-agnostic: it targets every output device whose transport type is HDMI or DisplayPort.
> Install with `./install.sh`. Requires Xcode Command Line Tools. MIT licensed.

HDMI / DisplayPort でつないだモニターの音声が、**スリープ復帰後や本体起動後に無音になる** macOS の不具合を自動で修復します。

## 症状

- 映像は正常に表示されているのに、**音だけがまったく出ない**
- システム設定でもデバイスは正常に見え、チャンネル数もサンプルレートも正しい
- 音量調整もミュート解除も効かない
- 動画サイトの再生まで止まる（アプリが音声デバイスの起動を待ってタイムアウトするため）
- **`sudo killall coreaudiod` も、出力先の切り替えも効かない**
- モニターの電源を入れ直すと直る

`log` にはこの形で残ります。

```
IsTimeRunning_Helper: Device ... is not running.
IOWorkLoop: could not establish a timeline after waiting 10000000 microseconds
StartIOThread: the IO thread failed to start, Error: 1937010544
IO Stopped Context ... after 0 frames.
```

`1937010544` は FourCC で `'stop'`。**再生を10秒待って1フレームも出さずに諦めている**状態です。

## 原因

スリープ復帰時や起動時に macOS がオーディオデバイスを破棄して作り直しますが、作り直されたエンドポイントがクロックを供給できない状態になることがあります。macOS はそれを既定の出力として選び直してしまうため、完全な無音になります。

**モニターの機種には依存しません。** 同じ症状を扱う先行実装 [DisplayAudioFix](https://github.com/TypeThe0ry/DisplayAudioFix) は別機種（Samsung LS24A600U）で同一の OS ビルド・同一のエラーコード・同一の復旧手段を報告しており、独立に同じ結論へ到達しています。[MonitorControl #806](https://github.com/MonitorControl/MonitorControl/issues/806) も同症状で、原因未特定のままクローズされています。

## 直し方

**公称サンプルレートを 48kHz ↔ 44.1kHz と一瞬往復させる**と復旧します。ストリームの再構成が走り、死んでいた I/O コンテキストが張り直されるためです。所要約2秒、音は鳴りません。ディスプレイのリフレッシュレートには影響しません。

手作業でやるなら「Audio MIDI 設定」でフォーマットを変えて戻すのと同じことです。このツールはそれを**自動で、適切なタイミングで**実行します。

## インストール

Xcode Command Line Tools が必要です（`xcode-select --install`）。

```sh
git clone https://github.com/<your-account>/macos-hdmi-audio-fix.git
cd macos-hdmi-audio-fix
./install.sh
```

CLI の設置先は既定で `~/bin` です。変えるなら `BIN_DIR=~/.local/bin ./install.sh`。

アンインストールは `./uninstall.sh`。

## 復旧が走る契機

| 契機 | タイミング | 備考 |
|------|-----------|------|
| **本体の起動** | プロセス開始の +15秒 / +30秒 / +50秒 | 起動直後はログイン項目が一斉に動きディスプレイの準備も遅れるため長めに待つ |
| **スリープ復帰** | `NSWorkspace.didWakeNotification` の +4秒 / +10秒 / +20秒 | |
| **再生失敗の検知** | 即時（90秒のデバウンス付き） | `log stream` で `coreaudiod` を購読し、失敗シグネチャを見つけたら復旧する |

複数回に分けているのは、復帰直後はデバイスがまだ戻りきっていないことがあるためです。オーディオデバイスは毎回 UID で引き直します（`AudioObjectID` は起動やスリープのたびに変わります）。

対象は**トランスポート種別が HDMI / DisplayPort の出力デバイスすべて**です。機種も UID も決め打ちしていないので、モニターを入れ替えてもそのまま動きます。

最後に**既定出力を一瞬別デバイスへ切り替えて戻します**。Slack や Discord などの Electron（Chromium）アプリは出力デバイスをキャッシュするため、デバイスが作り直されると古いハンドルを掴んだまま無音になることがあります。デバイス変更通知を飛ばして再取得させるのが狙いです（効果は検証中）。

## コマンド

```sh
audio-fix status          # HDMI/DP デバイスの一覧と現在のサンプルレート
audio-fix repair          # 手動で復旧する
audio-fix bounce-default  # 既定出力を切り替えて戻す（Electron アプリ対策）
audio-fix devices         # UID とデバイス名の対応
audio-fix watch           # 常駐（通常は LaunchAgent が実行する）

audio-revive              # 無音を判定し、復旧手段を順に試して効いたものを報告する
audio-last [分]           # 直近の再生を出力先・長さ付きで一覧する
```

## 診断のしかた

このツールの肝は、**「音が鳴らない」という主観を数値に落とす**ことです。`coreaudiod` のログには、再生が終わるたびに**実際にデバイスへ届いたフレーム数**が残ります。

```sh
/usr/bin/log show --last 30m --predicate 'process == "coreaudiod"' | grep 'IO Stopped Context'
```

```
IO Stopped Context 8822 after 0 frames.       → 完全に無音（この不具合）
IO Stopped Context 8822 after 67584 frames.   → 1.408秒ぶん再生された（正常）
IO Stopped Context 8822 after 2560 frames.    → 0.053秒だけ = 一瞬で切れている
```

48000 で割れば秒数です。`audio-last` はこれをデバイス名付きで整形します。

- **再生記録が無い** → 音声デバイスまで届いていない。アプリ側か通知設定の問題
- **0 frames** → この不具合。`audio-revive` で直る
- **正常な長さなのに聞こえない** → 音量・ミュート・出力先の取り違え

`log` は zsh のビルトインと衝突するので、スクリプト内では `/usr/bin/log` と書く必要があります。

## 効かなかった対処（実測）

ネット上でよく挙がる対処のうち、この症状に効かなかったものです。すべて上記のフレーム数で確認しています。

| 対処 | 結果 |
|------|------|
| `sudo killall coreaudiod` | **効かない**。プロセスを作り直しても同じデバイスが 0 frames のまま |
| 出力先を別デバイスに切り替えて戻す | **効かない** |
| 無音を流し続けてデバイスを起動状態に保つ | **効かない** |
| 古い HAL プラグイン（`/Library/Audio/Plug-Ins/HAL/`）の整理 | **無関係**。別デバイスは同じ CoreAudio 上で正常に鳴る |
| モニターの電源を入れ直す | 効く（ただし手作業） |
| **サンプルレートの往復** | **効く** ← このツールが使う手段 |

## 実装上の注意点

- **本体起動時は `NSWorkspace.didWakeNotification` が飛びません。** スリープ復帰だけを契機にすると、再起動後に復旧処理が一度も走らないまま無音が続きます
- **`AudioObjectID` は起動やスリープのたびに変わります。** キャッシュせず毎回 UID で引き直す必要があります
- 失敗検知に無音テスト再生ではなく**ログ購読**を使っています。テスト再生すると診断用の再生記録を自分で汚してしまうためです

## 動作確認環境

- Mac mini (M1, 2020) / macOS 27.0 (26A428)
- HDMI 接続のモニター2台（内蔵 HDMI ポートと USB-C の両方）

他のバージョンや機種では未確認です。

## 対象外の既知の問題

**システムのアラート音（NSBeep）が一瞬しか鳴らない。** 再生開始から約273msで打ち切られる一方、音が流れ出すまで80〜260msの空白があるため30〜160msしか出ません。**内蔵スピーカーでも同じ**なので、このツールが扱う HDMI の問題とは別件です。実際の通知音（`display notification`）は正常に鳴ります。緩和策はアラート音を立ち上がりの鋭いもの（Tink / Pop / Bottle）に変えることです。

## 謝辞

先行実装の [DisplayAudioFix](https://github.com/TypeThe0ry/DisplayAudioFix) に、同一のバグ・エラーコード・復旧手段が記録されています。本リポジトリは独立に同じ結論へ到達したもので、診断手法とトリガー設計に重点を置いています。

## ライセンス

MIT License — [LICENSE](LICENSE) を参照してください。
