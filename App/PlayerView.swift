import MonoOtoAudio
import MonoOtoCore
import SwiftUI

/// Task 4 host: starting this app never starts an audio graph.
@MainActor
struct PlayerView: View {
    @StateObject private var output = DeviceOutput()
    @State private var playback = PlaybackState()
    @State private var devices: [OutputDevice] = []
    @State private var selectedUID = ""
    @State private var message = "停止中"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MonoOto — 無音の出力経路テスト").font(.title2)
            Text("この段階では音は再生しません。選択した機器への接続と停止を確認します。")
            HStack {
                Text("音声出力機器").font(.headline)
                Spacer()
                Text("\(devices.count) 件").foregroundStyle(.secondary)
                Button("一覧を更新", action: refresh)
                    .accessibilityLabel("音声出力機器の一覧を更新")
            }
            if devices.isEmpty {
                ContentUnavailableView {
                    Label("出力機器が見つかりません", systemImage: "speaker.slash")
                } description: {
                    Text("ヘッドホンやオーディオ機器を接続し、「一覧を更新」を押してください。")
                }
                .frame(height: 170)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(devices) { device in
                            Button {
                                guard device.isSupportedForStageA else { return }
                                stop()
                                selectedUID = device.uid
                                message = "\(device.name)を選択しました。開始操作を待っています。"
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedUID == device.uid ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedUID == device.uid ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name).font(.body.weight(.medium))
                                        Text("\(device.channels) ch · \(device.sampleRate.formatted(.number.precision(.fractionLength(0)))) Hz")
                                            .font(.caption).foregroundStyle(.secondary)
                                        if !device.isSupportedForStageA {
                                            Text(unsupportedReason(for: device))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedUID == device.uid { Text("選択中").font(.caption) }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedUID == device.uid ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!device.isSupportedForStageA)
                            .accessibilityLabel(deviceAccessibilityLabel(device))
                            .accessibilityValue(selectedUID == device.uid ? "選択中" : "未選択")
                        }
                    }
                }
                .frame(minHeight: 150, maxHeight: 240)
            }
            if let selected = devices.first(where: { $0.uid == selectedUID }) {
                Text("出力先: \(selected.name)").font(.callout)
            } else {
                Text("出力先を選択してください").foregroundStyle(.secondary)
            }
            HStack {
                Button("選択機器で無音テストを開始", action: startSilence)
                    .disabled(
                        output.isRunning ||
                        !devices.contains(where: { $0.uid == selectedUID && $0.isSupportedForStageA })
                    )
                Button("停止", action: stop)
                    .keyboardShortcut(".", modifiers: .command)
            }
            Text(message)
                .accessibilityLabel("状態: \(message)")
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text("無音コールバック: \(output.callbackCount) 回 / 確認済み機器ID: \(output.verifiedDeviceID.map(String.init) ?? "未接続")")
                    .font(.caption.monospacedDigit())
            }
            Text("効果は検証中です。聞こえ方や安全な音圧を保証するものではありません。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 480)
        .task { refresh() }
        .onChange(of: output.isRunning) { _, running in
            if !running {
                playback.stop()
                message = output.lastError ?? "停止中"
            }
        }
        .onChange(of: output.lastError) { _, error in
            if let error { message = error }
        }
        .onDisappear { stop(); output.dispose() }
    }

    private func refresh() {
        stop()
        do {
            devices = try DeviceOutput.availableDevices().sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if !devices.contains(where: { $0.uid == selectedUID }) { selectedUID = "" }
            message = devices.isEmpty ? "対応する出力機器が見つかりません" : "機器を選択して開始してください"
        } catch {
            devices = []
            selectedUID = ""
            message = "音声機器を取得できません。接続を確認してください。"
        }
    }

    private func startSilence() {
        guard let device = devices.first(where: {
            $0.uid == selectedUID && $0.isSupportedForStageA
        }) else { return }
        let ticket = playback.beginPreparation()
        do {
            try output.prepare(uid: device.uid, sampleRate: device.sampleRate)
            guard playback.finishPreparation(ticket) else {
                abortStart(message: "準備が取り消されたため停止しました。")
                return
            }
            try output.startSilence()
            guard playback.start(ticket) else {
                abortStart(message: "開始が取り消されたため停止しました。")
                return
            }
            message = "無音テスト中（\(device.name)）"
        } catch {
            output.stop()
            playback.stop()
            message = output.lastError ?? "開始できません。選択機器の接続と形式を確認してください。"
        }
    }

    private func stop() {
        playback.stop()
        output.stop()
        message = "停止中"
    }

    private func abortStart(message: String) {
        playback.stop()
        output.stop()
        self.message = message
    }

    private func unsupportedReason(for device: OutputDevice) -> String {
        if device.channels != 2 { return "非対応：2チャンネル出力ではありません" }
        return "非対応：44.1 kHzまたは48 kHzではありません"
    }

    private func deviceAccessibilityLabel(_ device: OutputDevice) -> String {
        let format = "\(device.channels)チャンネル、\(device.sampleRate.formatted())ヘルツ"
        return device.isSupportedForStageA
            ? "\(device.name)、\(format)"
            : "\(device.name)、\(format)、\(unsupportedReason(for: device))"
    }
}
