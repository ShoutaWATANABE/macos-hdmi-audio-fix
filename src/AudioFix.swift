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

func deviceUID(_ dev: AudioObjectID) -> String? {
    stringProperty(dev, kAudioDevicePropertyDeviceUID)
}

/// UID からデバイスを引く。`AudioObjectID` は起動やスリープのたびに変わるので、
/// ログで特定したデバイスを追うにはこちらを使う。
func device(forUID target: String) -> AudioObjectID? {
    let devices = allDevices()
    if let exact = devices.first(where: { deviceUID($0) == target }) { return exact }
    // ログ中の UID は区切りで切れていることがあるので前方一致でも探す。
    // 短い文字列での誤一致を避けるため、ある程度の長さを要求する。
    guard target.count >= 8 else { return nil }
    return devices.first {
        guard let uid = deviceUID($0) else { return false }
        return uid.hasPrefix(target) || target.hasPrefix(uid)
    }
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

/// HDMI / DisplayPort でつながった出力デバイスか。これがこのバグの対象。
func isDisplayOutput(_ dev: AudioObjectID) -> Bool {
    guard hasOutputStreams(dev) else { return false }
    let t = transportType(dev)
    return t == kAudioDeviceTransportTypeHDMI || t == kAudioDeviceTransportTypeDisplayPort
}

func displayOutputs() -> [AudioObjectID] {
    allDevices().filter(isDisplayOutput)
}

/// 取得できなければ nil。0 を返すと「レート不明」と「0 Hz」が区別できず、
/// 復旧の成否判定を誤るため区別する。
func nominalRate(_ dev: AudioObjectID) -> Float64? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var r: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &r) == noErr else { return nil }
    return r
}

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

func setDefaultOutput(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var d = dev
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioObjectID>.size), &d) == noErr
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

/// 復旧処理の 1 ステップの結果。ok が false のものは「効かなかった」ことを
/// 意味するので、ログにも終了ステータスにも必ず反映する。
typealias StepResult = (message: String, ok: Bool)

// MARK: - 復旧処理

/// 公称サンプルレートを別の値にして戻し、I/O コンテキストを作り直させる。
///
/// CoreAudio への書き込みは noErr を返しても反映されないことがあるため、
/// 往路・復路とも「書き込みの戻り値」と「読み直した現在値」の両方を確認する。
/// 往路が反映されていなければ I/O は作り直されていないので、成功とは呼べない。
func cycleRate(_ dev: AudioObjectID) -> StepResult {
    let label = name(dev)
    guard let orig = nominalRate(dev) else {
        return ("★\(label): 現在のサンプルレートを取得できず、復旧を実行せず", false)
    }
    // 48k ↔ 44.1k の往復が広く知られた有効手段なので、その2つを優先して選ぶ。
    let rates = availableRates(dev)
    let preferred: [Float64] = [44100, 48000, 96000, 32000]
    let alt = preferred.first { $0 != orig && rates.contains($0) }
        ?? rates.first { $0 != orig }
        ?? (orig == 44100 ? 48000 : 44100)

    let wroteAlt = setNominalRate(dev, alt)
    Thread.sleep(forTimeInterval: 0.8)
    let applied = nominalRate(dev)
    guard wroteAlt, applied == alt else {
        // 往路が効いていないので復路も不要。値がずれていたときだけ元に戻す。
        if let applied, applied != orig { _ = setNominalRate(dev, orig) }
        let now = applied.map { "（現在 \(Int($0)) Hz）" } ?? "（現在値を取得できず）"
        return ("★\(label): \(Int(orig)) → \(Int(alt)) Hz が反映されず、復旧できていません\(now)", false)
    }

    let wroteOrig = setNominalRate(dev, orig)
    Thread.sleep(forTimeInterval: 0.3)
    let restored = nominalRate(dev)
    guard wroteOrig, restored == orig else {
        let now = restored.map { "\(Int($0)) Hz" } ?? "取得できず"
        return ("★\(label): \(Int(orig)) → \(Int(alt)) Hz は成功したが "
                + "\(Int(orig)) Hz に戻せず（現在 \(now)）", false)
    }
    return ("\(label): \(Int(orig)) → \(Int(alt)) → \(Int(orig)) Hz", true)
}

/// 既定出力を別デバイスへ一瞬切り替えて戻す。
/// Electron（Slack / Discord など）は出力デバイスをキャッシュするため、
/// デバイス変更通知を受け取らせて再取得させるのが狙い。
///
/// 退避が失敗すると現在値が元のままなので、確認しないと「戻せた」に見えてしまう。
/// 往路・復路それぞれで実際に切り替わったかを読み直して確かめる。
func bounceDefaultOutput() -> StepResult {
    guard let cur = defaultOutput() else { return ("★既定出力を取得できず", false) }
    let curName = name(cur)
    guard let other = allDevices().first(where: { $0 != cur && hasOutputStreams($0) }) else {
        return ("切り替え先が無く実行せず", true)
    }

    let wroteOther = setDefaultOutput(other)
    Thread.sleep(forTimeInterval: 1.0)
    guard wroteOther, defaultOutput() == other else {
        // 切り替わっていないので復帰も不要。既定出力は元のまま。
        return ("★既定出力を \(name(other)) へ切り替えられず、バウンス未実行（\(curName) のまま）", false)
    }

    let wroteBack = setDefaultOutput(cur)
    Thread.sleep(forTimeInterval: 0.3)
    if wroteBack, defaultOutput() == cur { return ("既定出力をバウンス（\(curName) は維持）", true) }
    // ID は作り直されると変わるので、名前で引き直して再設定する
    if let again = allDevices().first(where: { name($0) == curName }),
       setDefaultOutput(again), defaultOutput() == again {
        return ("既定出力をバウンス（\(curName) を再設定して復帰）", true)
    }
    let now = defaultOutput().map(name) ?? "不明"
    return ("★既定出力を \(curName) に戻せませんでした（現在 \(now)）", false)
}

/// 既定出力のバウンスは、いま直したデバイスが既定出力のときだけ行う。
/// 無関係なデバイス（AirPods など）を使っている最中に既定出力を触ると、
/// 選択が別デバイスに残る事故のほうが大きい。
func bounceDefaultOutputIfTargeted(_ repaired: [AudioObjectID]) -> StepResult {
    guard !repaired.isEmpty else { return ("対象デバイスが無く、既定出力のバウンスは行わず", true) }
    guard let def = defaultOutput() else { return ("★既定出力を取得できず、バウンスは行わず", false) }
    guard repaired.contains(def) else {
        return ("既定出力（\(name(def))）は今回の対象外のため、バウンスは行わず", true)
    }
    return bounceDefaultOutput()
}

// MARK: - 排他制御

/// 復旧処理は絶対に同時に走らせない。
/// 片方が元レートを退避している最中にもう片方が現在値を読むと、変更後の値を
/// 「元の値」として記録し、48k のデバイスを 44.1k で確定させてしまう。
/// 既定出力のバウンスも同じ理由で競合し、別デバイスが選ばれたまま残りうる。
///
/// プロセス内はシリアルキュー（RecoveryScheduler）で、プロセス間は flock で
/// 直列化する。常駐プロセスが復旧している最中に、手動の `audio-fix repair` や
/// `audio-revive` が走るのは十分あり得るため、両方が要る。
let lockPath: String = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
        ?? NSTemporaryDirectory()
    return base + "/io.github.macos-hdmi-audio-fix.lock"
}()

func withRecoveryLock<T>(_ body: () -> T) -> T {
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    // ロックファイルを開けない環境でも復旧自体は動かす（直列化だけ諦める）
    guard fd >= 0 else { return body() }
    defer {
        flock(fd, LOCK_UN)
        close(fd)
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        logLine("他のプロセスが復旧処理中のため、終わるまで待機します")
        flock(fd, LOCK_EX)
    }
    return body()
}

/// 復旧要求の直列化と、実行待ちの重複要求の統合。
final class RecoveryScheduler {
    private let queue = DispatchQueue(label: "io.github.macos-hdmi-audio-fix.recovery")
    private let lock = NSLock()
    private var pending = Set<String>()

    /// 同じ対象の復旧がまだ開始されていなければ、この要求は統合して捨てる。
    /// 実行中のものへは合流させず後ろに並べる（直列なので壊れない）。
    func request(reason: String, delays: [Double], targetUID: String? = nil,
                 completion: (() -> Void)? = nil) {
        let key = targetUID ?? "*"
        lock.lock()
        let duplicate = pending.contains(key)
        if !duplicate { pending.insert(key) }
        lock.unlock()

        guard !duplicate else {
            logLine("\(reason) → 同じ対象の復旧処理が実行待ちのため統合（新たには起動せず）")
            completion?()
            return
        }
        queue.async {
            self.lock.lock()
            self.pending.remove(key)
            self.lock.unlock()
            _ = withRecoveryLock { runRecovery(reason: reason, delays: delays, targetUID: targetUID) }
            completion?()
        }
    }
}

let scheduler = RecoveryScheduler()

// MARK: - watch モード

/// 復旧を走らせる。delays は「前回からの待ち時間」の列。
/// デバイスが戻りきっていないことがあるため間隔を空けて複数回試す。
/// targetUID を渡すと、そのデバイスだけを対象にする。
///
/// 必ず withRecoveryLock 経由で、かつ RecoveryScheduler のキュー上で呼ぶこと。
@discardableResult
func runRecovery(reason: String, delays: [Double], targetUID: String? = nil) -> Bool {
    logLine("\(reason) → 復旧処理を開始")
    var allOK = true
    var repaired: [AudioObjectID] = []

    for (i, delay) in delays.enumerated() {
        Thread.sleep(forTimeInterval: delay)
        // AudioObjectID は毎回引き直す（起動・スリープのたびに変わるため）
        let targets: [AudioObjectID]
        if let targetUID {
            targets = device(forUID: targetUID).filter(isDisplayOutput).map { [$0] } ?? []
        } else {
            targets = displayOutputs()
        }
        if targets.isEmpty {
            logLine("  試行\(i + 1): 対象のディスプレイ音声デバイスが見つからず、スキップ")
            continue
        }
        repaired = targets
        for dev in targets {
            let step = cycleRate(dev)
            if !step.ok { allOK = false }
            logLine("  試行\(i + 1): \(step.message)")
        }
    }

    let bounce = bounceDefaultOutputIfTargeted(repaired)
    if !bounce.ok { allOK = false }
    logLine("  " + bounce.message)
    logLine(allOK ? "復旧処理を完了" : "★復旧処理を完了（失敗した手順があります）")
    return allOK
}

extension Optional where Wrapped == AudioObjectID {
    /// 条件を満たさなければ nil にする小道具（対象 UID のデバイスが
    /// ディスプレイ音声でなくなっていた場合を弾く）。
    func filter(_ isIncluded: (Wrapped) -> Bool) -> Wrapped? {
        guard let self, isIncluded(self) else { return nil }
        return self
    }
}

/// "…IOWorkLoopInit: 365 410C17C2-… (410C17C2-…): starting" から
/// (コンテキストID, デバイス UID) を取り出す。
func parseWorkLoopInit(_ line: String) -> (context: String, uid: String)? {
    guard let r = line.range(of: "IOWorkLoopInit: ") else { return nil }
    let fields = line[r.upperBound...].split(separator: " ", maxSplits: 2)
    guard fields.count >= 2 else { return nil }
    let context = String(fields[0])
    let uid = String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    guard !context.isEmpty, context.allSatisfy(\.isNumber), !uid.isEmpty else { return nil }
    return (context, uid)
}

/// marker の直後に続く数字を取り出す。"… for context 365 <private>" → "365"
func parseNumber(in line: String, after marker: String) -> String? {
    guard let r = line.range(of: marker) else { return nil }
    let digits = line[r.upperBound...].prefix(while: \.isNumber)
    return digits.isEmpty ? nil : String(digits)
}

/// coreaudiod のログを購読し、再生失敗のシグネチャを見つけたら通知する。
/// 無音テストを再生する必要がないので、音にも診断ログにも影響しない。
///
/// 失敗行そのものにはデバイス名も UID も載らない（`<private>` でマスクされる）が、
/// 同じ事象の約10秒前に出る IOWorkLoopInit 行がコンテキストID と UID の対応を持つ。
///
///   IOWorkLoopInit: 365 410C17C2-…: starting
///   IOWorkLoop: could not establish a timeline after waiting 10000000 microseconds for context 365 <private>
///
/// これを覚えておき、失敗したのがどのデバイスかを特定してから復旧する。
/// "the IO thread failed to start" も同じ事象で出るが、コンテキストID を持たず
/// 対象を特定できない。実測では必ず上の行と対で出るため、契機には使わない。
///
/// onFailure の第3引数は「対応表を一度でも作れたか」。ログ形式が変わって
/// 対応が取れなくなったときに検知そのものが死なないよう、呼び出し側で
/// 従来どおりの全台対象へ縮退するために渡している。
func startLogMonitor(onFailure: @escaping (_ context: String?, _ uid: String?, _ mapped: Bool) -> Void) {
    let failureSignature = "could not establish a timeline"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    task.arguments = ["stream", "--style", "compact",
                      "--predicate", #"process == "coreaudiod""#]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    var buffer = Data()
    var contextToUID: [String: String] = [:]
    var everMapped = false

    pipe.fileHandleForReading.readabilityHandler = { handle in
        buffer.append(handle.availableData)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(data: buffer[..<nl], encoding: .utf8) ?? ""
            buffer.removeSubrange(...nl)

            if let init_ = parseWorkLoopInit(line) {
                // 際限なく溜めない。コンテキストID は失敗の直前に出るので、
                // 古い対応を捨てても検知には影響しない。
                if contextToUID.count > 64 { contextToUID.removeAll() }
                contextToUID[init_.context] = init_.uid
                everMapped = true
                continue
            }
            guard line.contains(failureSignature) else { continue }
            let context = parseNumber(in: line, after: "for context ")
            onFailure(context, context.flatMap { contextToUID[$0] }, everMapped)
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
    scheduler.request(reason: "起動を検出", delays: [15.0, 15.0, 20.0])

    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
    ) { _ in
        scheduler.request(reason: "スリープ復帰を検出", delays: [4.0, 6.0, 10.0])
    }

    // 起動・復帰以外のタイミングで壊れた場合の保険。
    // 復旧処理自体もログに失敗シグネチャを出しうるので、多重発火を抑える。
    let debounce = DispatchQueue(label: "io.github.macos-hdmi-audio-fix.debounce")
    var lastRepair = Date.distantPast

    startLogMonitor { context, failedUID, mapped in
        debounce.async {
            guard Date().timeIntervalSince(lastRepair) > 90 else { return }
            let where_ = context.map { "context \($0)" } ?? "context 不明"

            if let failedUID {
                guard let dev = device(forUID: failedUID) else {
                    logLine("再生失敗を検知（\(where_)）— 該当デバイスが見つからないため復旧しません")
                    return
                }
                guard isDisplayOutput(dev) else {
                    logLine("再生失敗を検知（\(where_) / \(name(dev))）"
                            + "— HDMI・DisplayPort ではないため復旧しません")
                    return
                }
                lastRepair = Date()
                scheduler.request(reason: "再生失敗を検知（\(name(dev))）",
                                  delays: [1.0], targetUID: failedUID) {
                    debounce.async { lastRepair = Date() }
                }
            } else if !mapped {
                // ログ形式が変わって対応表を作れないときは、検知が死ぬより
                // 従来どおり全台を対象にするほうがましなので縮退する。
                lastRepair = Date()
                scheduler.request(reason: "再生失敗を検知（対象を特定できず全デバイスを対象）",
                                  delays: [1.0]) {
                    debounce.async { lastRepair = Date() }
                }
            } else {
                logLine("再生失敗を検知（\(where_)）— 対象デバイスを特定できないため復旧しません")
            }
        }
    }

    RunLoop.main.run()

case "repair":
    // 常駐プロセスの復旧と重ならないよう、ロックを取ってから対象を読み直す
    let ok = withRecoveryLock { () -> Bool in
        let targets = displayOutputs()
        guard !targets.isEmpty else {
            print("ディスプレイ音声デバイス（HDMI / DisplayPort）が見つかりません")
            return false
        }
        var allOK = true
        for dev in targets {
            let step = cycleRate(dev)
            print(step.message)
            if !step.ok { allOK = false }
        }
        let bounce = bounceDefaultOutputIfTargeted(targets)
        print(bounce.message)
        return allOK && bounce.ok
    }
    if !ok { exit(1) }

case "bounce-default":
    let step = withRecoveryLock { bounceDefaultOutput() }
    print(step.message)
    if !step.ok { exit(1) }

case "devices":
    // UID とデバイス名の対応を出力する。ログの UID を名前に直すのに使う。
    for dev in allDevices() {
        guard let uid = deviceUID(dev) else { continue }
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
        let rate = nominalRate(dev).map { "\(Int($0)) Hz" } ?? "レート不明"
        print("  \(name(dev))  \(rate)  [選択可: \(rates)]\(mark)")
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
