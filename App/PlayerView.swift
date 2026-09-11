import AppKit
import MonoOtoAudio
import MonoOtoCore
import SwiftUI
import UniformTypeIdentifiers

/// Minimal Task 6 host. Opening a file or selecting an output never starts playback.
@MainActor
struct PlayerView: View {
    @StateObject private var playback = PlaybackController()
    @State private var devices: [OutputDevice] = []
    @State private var uid = ""
    @State private var ear: HearingEar?
    @State private var fileName = "ファイル未選択"
    @State private var mode: ListeningMode = .mono
    @State private var strength: Double = 0.35
    @State private var cutoff: Double = 1_500
    @State private var gain: Double = -18
    @State private var muted = false
    @State private var seekPosition = 0.0
    @State private var isSeeking = false
    @State private var message: String?
    @State private var actionInFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MonoOto").font(.title2)
            Text("片耳でステレオ音源の手がかりを探るプレーヤー")
            Text("効果は個人差があり検証中です。無理のない音量で、違和感があれば停止してください。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("出力機器", selection: $uid) {
                    Text("選択してください").tag("")
                    ForEach(devices.filter(\.isSupportedForStageA)) { device in
                        Text("\(device.name)（\(Int(device.sampleRate)) Hz）").tag(device.uid)
                    }
                }.accessibilityLabel("音声出力機器")
                Button("一覧を更新", action: refresh).accessibilityLabel("音声出力機器の一覧を更新")
            }
            Picker("聞こえる耳", selection: $ear) {
                Text("選択してください").tag(HearingEar?.none)
                Text("左耳").tag(HearingEar?.some(.left))
                Text("右耳").tag(HearingEar?.some(.right))
            }.accessibilityLabel("音を出力する聞こえる耳")
            HStack {
                Button("ファイルを開く", action: openFile).disabled(actionInFlight)
                Text(fileName).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("確認音") { perform { try await playback.playConfirmationTone() } }
                    .disabled(actionInFlight || uid.isEmpty || ear == nil)
                    .accessibilityLabel("選択した耳へ短い確認音を再生")
            }
            Text("非DRM WAV / AIFF・モノラルまたはステレオ・44.1 / 48 kHz")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(playback.phase == .running ? "一時停止" : "再生") {
                    if playback.phase == .running { playback.pause() }
                    else { perform { try await playback.play() } }
                }
                .disabled(actionInFlight || uid.isEmpty || ear == nil || playback.channelCount == 0 ||
                          playback.phase == .preparing || playback.phase == .stopping)
                .accessibilityLabel(playback.phase == .running ? "再生を一時停止" : "選択した音源を再生")
                Button("停止") { playback.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityLabel("再生を停止して先頭に戻る")
                Spacer()
                Text(phaseLabel).accessibilityLabel("再生状態: \(phaseLabel)")
            }
            HStack {
                Slider(value: $seekPosition, in: 0...max(0.001, playback.durationSeconds)) { editing in
                    isSeeking = editing
                    if !editing { perform { try await playback.seek(seconds: seekPosition) } }
                }
                .disabled(actionInFlight || !playback.canSeek || playback.phase == .preparing || playback.phase == .stopping)
                .accessibilityLabel("再生位置（アプリ供給済み音声の概算）")
                Text("\(Int(seekPosition)) / \(Int(playback.durationSeconds)) 秒").monospacedDigit()
            }
            Picker("比較モード", selection: $mode) {
                Text("通常モノラル").tag(ListeningMode.mono)
                Text("音色の手がかり").tag(ListeningMode.cue)
                Text("入力Lのみ").tag(ListeningMode.leftOnly).disabled(playback.channelCount == 1)
                Text("入力Rのみ").tag(ListeningMode.rightOnly).disabled(playback.channelCount == 1)
            }.accessibilityLabel("音源の比較モード。LとRは入力チャンネル")
            control("手がかりの強さ", value: $strength, range: 0...0.6,
                    text: strength.formatted(.number.precision(.fractionLength(2))))
            control("基準周波数", value: $cutoff, range: 800...4_000, text: "\(Int(cutoff)) Hz")
            control("アプリ内音量", value: $gain, range: -60...0, text: "\(Int(gain)) dB")
            Toggle("ミュート", isOn: $muted).accessibilityLabel("アプリの音をミュート")
            if playback.cancellationWarning {
                Text("位相の影響で音が小さくなる可能性があります。")
                    .foregroundStyle(.orange).accessibilityLabel("位相による相殺の警告")
            }
            if let error = playback.lastError ?? message {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("エラー: \(error)")
            }
            Text("デジタル出力の制限は、耳元の安全な音圧を保証しません。OSの音量は変更しません。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24).frame(minWidth: 620, minHeight: 600)
        .task { refresh() }
        .onChange(of: uid) { _, _ in selectOutput() }
        .onChange(of: ear) { _, _ in selectOutput() }
        .onChange(of: playback.mode) { _, accepted in mode = accepted }
        .onChange(of: mode) { old, _ in
            if !applySettings() { mode = old }
        }
        .onChange(of: strength) { _, _ in _ = applySettings() }
        .onChange(of: cutoff) { _, _ in _ = applySettings() }
        .onChange(of: gain) { _, _ in _ = applySettings() }
        .onChange(of: muted) { _, _ in _ = applySettings() }
        .onChange(of: playback.positionSeconds) { _, position in if !isSeeking { seekPosition = position } }
        .onDisappear { playback.stop() }
    }

    private func control(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(label)
            Text(text).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
    }
    private var phaseLabel: String {
        switch playback.phase {
        case .stopped: "停止中"
        case .preparing: "準備中"
        case .running: "再生中"
        case .paused: "一時停止中"
        case .stopping: "停止処理中"
        case .error: "エラー"
        }
    }
    private func refresh() {
        playback.stop()
        do {
            devices = try DeviceOutput.availableDevices().sorted { $0.name < $1.name }
            if !devices.contains(where: { $0.uid == uid && $0.isSupportedForStageA }) { uid = "" }
            message = devices.contains(where: \.isSupportedForStageA) ? nil : "対応する2チャンネル出力機器を接続してください。"
        } catch { message = "出力機器を取得できません。接続を確認してください。" }
    }
    private func selectOutput() {
        playback.stop()
        if let ear, !uid.isEmpty { playback.selectOutput(uid: uid, ear: ear) }
    }
    private func openFile() {
        guard !actionInFlight else { return }
        actionInFlight = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { actionInFlight = false; return }
            Task { @MainActor in
                defer { actionInFlight = false }
                do { try await playback.open(url: url); fileName = url.lastPathComponent; message = nil }
                catch { message = "音源を開けません。対応形式を確認してください。" }
            }
        }
    }
    @discardableResult private func applySettings() -> Bool {
        do {
            try playback.set(mode: mode, parameters: .init(strength: Float(strength), cutoffHz: Float(cutoff)),
                             gainDB: muted ? nil : Float(gain))
            message = nil
            return true
        } catch {
            mode = playback.mode
            strength = Double(playback.parameters.strength)
            cutoff = Double(playback.parameters.cutoffHz)
            muted = playback.gainDB == nil
            if let acceptedGain = playback.gainDB { gain = Double(acceptedGain) }
            message = "設定を適用できません。表示を前の設定に戻しました。"
            return false
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !actionInFlight else { return }
        actionInFlight = true
        Task { @MainActor in
            defer { actionInFlight = false }
            do { try await action(); message = nil }
            catch is CancellationError { }
            catch { message = "操作を完了できません。出力先と音源を確認してください。" }
        }
    }
}
