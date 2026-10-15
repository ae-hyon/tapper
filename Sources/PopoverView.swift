// 메뉴바 팝오버 UI. 한 화면에 전부 들어가도록 유지한다.

import SwiftUI

struct PopoverView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: Settings

    init(controller: AppController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    private var isActive: Bool { controller.state != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.axTrusted { permissionBanner }
            if let warning = controller.hotkeyWarning { warningBanner(warning) }

            targetRow
            intervalRow
            modeRow
            if settings.mode != .toggle { modeDetailRow }

            Divider()
            optionsSection
            Divider()

            startButton
            statusSection

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 310)
        .onAppear { controller.refreshTrust() }
    }

    // MARK: - 권한

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("손쉬운 사용 권한 필요", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text("권한이 없으면 클릭이 전송되지 않고 조용히 무시됩니다.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("권한 요청") { controller.requestAXPermission() }
                Button("설정 열기") { controller.openAXSettings() }
                Button("다시 확인") { controller.refreshTrust() }
            }
            .font(.system(size: 11))
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func warningBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .padding(8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 설정 행

    private var targetRow: some View {
        HStack {
            Text("좌표").font(.system(size: 12)).frame(width: 52, alignment: .leading)
            Text(settings.hasTarget
                 ? "(\(Int(settings.targetX)), \(Int(settings.targetY)))"
                 : "미지정")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(settings.hasTarget ? .primary : .secondary)
            Spacer()
            Button("지정 \(HotKey.capture.label)") { controller.captureTarget() }
                .font(.system(size: 11))
                .disabled(isActive)
        }
    }

    private var intervalRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("간격").font(.system(size: 12)).frame(width: 52, alignment: .leading)
                Slider(value: $settings.intervalMs,
                       in: Settings.intervalRange, step: 1)
                    .disabled(isActive)
                Text("\(Int(settings.intervalMs))ms")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 58, alignment: .trailing)
            }
            Text("요청 \(String(format: "%.1f", 1000 / settings.intervalMs)) tap/s")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 52)
        }
    }

    private var modeRow: some View {
        HStack {
            Text("모드").font(.system(size: 12)).frame(width: 52, alignment: .leading)
            Picker("", selection: $settings.mode) {
                ForEach(UIMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isActive)
        }
    }

    @ViewBuilder
    private var modeDetailRow: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 52)
            if settings.mode == .duration {
                // 키보드 입력과 1단위 스테퍼를 같은 값에 묶는다.
                // 범위를 벗어난 입력은 Settings의 didSet이 커밋 시점에 정규화한다.
                TextField("", value: $settings.durationSec, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 62)
                Stepper("", value: $settings.durationSec,
                        in: Settings.durationRange, step: 1)
                    .labelsHidden()
                Text("초 동안").font(.system(size: 12))
            } else {
                TextField("", value: $settings.countLimit, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 62)
                Stepper("", value: $settings.countLimit,
                        in: Settings.countRange, step: 1)
                    .labelsHidden()
                Text("회").font(.system(size: 12))
            }
            Spacer()
        }
        .disabled(isActive)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper("시작 지연 \(Int(settings.startDelaySec))초",
                    value: $settings.startDelaySec, in: 0...10, step: 1)
                .font(.system(size: 12))
            Stepper("누름 유지 \(Int(settings.holdMs))ms",
                    value: $settings.holdMs, in: Settings.holdRange, step: 1)
                .font(.system(size: 12))
            Toggle("대상 창이 바뀌면 자동 정지", isOn: $settings.guardFocus)
                .font(.system(size: 12))
            Text(settings.mode.hint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .disabled(isActive)
    }

    // MARK: - 시작 / 상태

    private var startButton: some View {
        Button {
            controller.toggle()
        } label: {
            Text(isActive ? "정지  \(HotKey.toggle.label)" : "시작  \(HotKey.toggle.label)")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
        }
        .tint(isActive ? .red : .accentColor)
        .buttonStyle(.borderedProminent)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.state == .running ? Color.green
                          : controller.state == .waiting ? Color.orange : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(controller.statusLine).font(.system(size: 11))
            }
            if controller.taps > 0 {
                // 이 값은 엔진이 '쏜' 횟수다. Clicker.tick()이 tapSink 직후
                // 카운터를 올리므로, 전송이 전부 버려져도 설정값대로 표시된다.
                // "실측"으로 적으면 화면에 반영된 횟수로 오해하게 된다.
                Text("\(controller.taps)회 · 전송 \(String(format: "%.1f", controller.rate)) tap/s")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("긴급정지 \(HotKey.panic.label)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button("종료") { NSApp.terminate(nil) }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}
