// ディスプレイ音声（HDMI / DisplayPort）の CoreAudio 再生不能を検知して復旧する。
//
// 症状: デバイスは正常に見えるのに再生が始まらず完全な無音になる。
//       ログに "could not establish a timeline" / Error 1937010544 ('stop') が出る。
// 復旧: 公称サンプルレートを一度別の値にして戻すと I/O コンテキストが再構築される。
//
// 特定のモニターに依存しない。トランスポート種別が HDMI / DisplayPort の
// 出力デバイスをすべて対象にするので、機種を変えてもそのまま動く。
//
// 詳細は ~/bin/README.md を参照。

import AppKit
import CoreAudio
import Foundation

// MARK: - CoreAudio ヘルパー

func stringProperty(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: sel,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    let st = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    return st == noErr ? (value as String?) : nil
}

func allDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func name(_ dev: AudioObjectID) -> String {
    stringProperty(dev, kAudioObjectPropertyName) ?? "(不明)"
}

func transportType(_ dev: AudioObjectID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var t: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &t)
    return t
}

func hasOutputStreams(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: kAudioDevicePropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr && size > 0
}

/// HDMI / DisplayPort でつながった出力デバイス。これがこのバグの対象。
func displayOutputs() -> [AudioObjectID] {
    allDevices().filter {
        hasOutputStreams($0)
            && (transportType($0) == kAudioDeviceTransportTypeHDMI
                || transportType($0) == kAudioDeviceTransportTypeDisplayPort)
    }
}

func nominalRate(_ dev: AudioObjectID) -> Float64 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var r: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &r)
    return r
}

@discardableResult
func setNominalRate(_ dev: AudioObjectID, _ rate: Float64) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var r = rate
    return AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                      UInt32(MemoryLayout<Float64>.size), &r) == noErr
}

func availableRates(_ dev: AudioObjectID) -> [Float64] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return [] }
    var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                   count: Int(size) / MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
    return ranges.map { $0.mMinimum }
}

func defaultOutput() -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var d: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &addr, 0, nil, &size, &d) == noErr ? d : nil
}

@discardableResult
func setDefaultOutput(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var d = dev
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioObjectID>.size), &d) == noErr
}

// MARK: - 復旧処理

/// 公称サンプルレートを別の値にして戻し、I/O コンテキストを作り直させる。
func cycleRate(_ dev: AudioObjectID) -> String {
    let orig = nominalRate(dev)
    // 48k ↔ 44.1k の往復が広く知られた有効手段なので、その2つを優先して選ぶ。
    let rates = availableRates(dev)
    let preferred: [Float64] = [44100, 48000, 96000, 32000]
    let alt = preferred.first { $0 != orig && rates.contains($0) }
        ?? rates.first { $0 != orig }
        ?? (orig == 44100 ? 48000 : 44100)
    setNominalRate(dev, alt)
    Thread.sleep(forTimeInterval: 0.8)
    setNominalRate(dev, orig)
    Thread.sleep(forTimeInterval: 0.3)
    let now = nominalRate(dev)
    let ok = now == orig ? "" : "（★\(Int(orig)) に戻せず \(Int(now))）"
    return "\(name(dev)): \(Int(orig)) → \(Int(alt)) → \(Int(now)) Hz\(ok)"
}

/// 既定出力を別デバイスへ一瞬切り替えて戻す。
/// Electron（Slack / Discord など）は出力デバイスをキャッシュするため、
/// デバイス変更通知を受け取らせて再取得させるのが狙い。
func bounceDefaultOutput() -> String {
    guard let cur = defaultOutput() else { return "既定出力を取得できず" }
    let curName = name(cur)
    guard let other = allDevices().first(where: { $0 != cur && hasOutputStreams($0) }) else {
        return "切り替え先が無く実行せず"
    }
    setDefaultOutput(other)
    Thread.sleep(forTimeInterval: 1.0)
    setDefaultOutput(cur)
    Thread.sleep(forTimeInterval: 0.3)
    if defaultOutput() == cur { return "既定出力をバウンス（\(curName) は維持）" }
    // ID は作り直されると変わるので、名前で引き直して再設定する
    if let again = allDevices().first(where: { name($0) == curName }) {
        setDefaultOutput(again)
        return "既定出力をバウンス（\(curName) を再設定して復帰）"
    }
    return "★既定出力を \(curName) に戻せませんでした"
}

// MARK: - ログ出力

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func logLine(_ message: String) {
    FileHandle.standardOutput.write("[\(stamp.string(from: Date()))] \(message)\n".data(using: .utf8)!)
}

// MARK: - watch モード

/// 復旧を走らせる。delays は「前回からの待ち時間」の列。
/// デバイスが戻りきっていないことがあるため間隔を空けて複数回試す。
func runRecovery(reason: String, delays: [Double]) {
    logLine("\(reason) → 復旧処理を開始")
    for (i, delay) in delays.enumerated() {
        Thread.sleep(forTimeInterval: delay)
        let targets = displayOutputs()
        if targets.isEmpty {
            logLine("  試行\(i + 1): ディスプレイ音声デバイスが見つからず、スキップ")
            continue
        }
        for dev in targets {
            logLine("  試行\(i + 1): " + cycleRate(dev))
        }
    }
    logLine("  " + bounceDefaultOutput())
    logLine("復旧処理を完了")
}

/// coreaudiod のログを購読し、再生失敗のシグネチャを見つけたら復旧する。
/// 無音テストを再生する必要がないので、音にも診断ログにも影響しない。
func startLogMonitor(onFailure: @escaping (String) -> Void) {
    let signatures = [
        "could not establish a timeline",
        "the IO thread failed to start",
    ]
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    task.arguments = ["stream", "--style", "compact",
                      "--predicate", #"process == "coreaudiod""#]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    var buffer = Data()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        buffer.append(handle.availableData)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(data: buffer[..<nl], encoding: .utf8) ?? ""
            buffer.removeSubrange(...nl)
            if let hit = signatures.first(where: { line.contains($0) }) {
                onFailure(hit)
            }
        }
    }
    do {
        try task.run()
        logLine("ログ監視を開始（再生失敗を検知したら自動で復旧します）")
    } catch {
        logLine("★ログ監視を開始できませんでした: \(error.localizedDescription)")
    }
}

// MARK: - main

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "status"

switch command {

case "watch":
    setbuf(stdout, nil)
    logLine("watch 開始 (PID \(getpid()))")

    // 本体起動時は didWakeNotification が飛ばないため、起動直後にも必ず走らせる。
    // 起動直後はログイン項目が一斉に動きディスプレイの準備も遅れるので長めに待つ。
    DispatchQueue.global().async {
        runRecovery(reason: "起動を検出", delays: [15.0, 15.0, 20.0])
    }

    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
    ) { _ in
        DispatchQueue.global().async {
            runRecovery(reason: "スリープ復帰を検出", delays: [4.0, 6.0, 10.0])
        }
    }

    // 起動・復帰以外のタイミングで壊れた場合の保険。
    // 復旧処理自体もログに失敗シグネチャを出しうるので、多重発火を抑える。
    let debounce = DispatchQueue(label: "monitor-audio-fix.debounce")
    var lastRepair = Date.distantPast
    startLogMonitor { signature in
        debounce.async {
            guard Date().timeIntervalSince(lastRepair) > 90 else { return }
            lastRepair = Date()
            DispatchQueue.global().async {
                runRecovery(reason: "再生失敗を検知（\(signature)）", delays: [1.0])
                debounce.async { lastRepair = Date() }
            }
        }
    }

    RunLoop.main.run()

case "repair":
    let targets = displayOutputs()
    if targets.isEmpty {
        print("ディスプレイ音声デバイス（HDMI / DisplayPort）が見つかりません")
        exit(1)
    }
    for dev in targets { print(cycleRate(dev)) }
    print(bounceDefaultOutput())

case "bounce-default":
    print(bounceDefaultOutput())

case "devices":
    // UID とデバイス名の対応を出力する。ログの UID を名前に直すのに使う。
    for dev in allDevices() {
        guard let uid = stringProperty(dev, kAudioDevicePropertyDeviceUID) else { continue }
        print("\(uid)\t\(name(dev))")
    }

case "status":
    let def = defaultOutput()
    print("ディスプレイ音声デバイス（HDMI / DisplayPort）:")
    let targets = displayOutputs()
    if targets.isEmpty { print("  なし") }
    for dev in targets {
        let mark = dev == def ? "  ← 既定出力" : ""
        let rates = availableRates(dev).map { String(Int($0)) }.joined(separator: "/")
        print("  \(name(dev))  \(Int(nominalRate(dev))) Hz  [選択可: \(rates)]\(mark)")
    }
    if let d = def, !targets.contains(d) {
        print("既定出力: \(name(d))（ディスプレイ音声ではない）")
    }

default:
    print("usage: audio-fix [status|repair|bounce-default|watch]")
    print("  status         デバイスの一覧と現在のサンプルレート")
    print("  repair         ディスプレイ音声デバイスを復旧する")
    print("  bounce-default 既定出力を切り替えて戻す（Electron アプリ対策）")
    print("  watch          常駐して起動・復帰・再生失敗を監視する")
    exit(1)
}
