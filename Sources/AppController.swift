// 엔진 · 핫키 · 안전장치를 묶는 레이어. SwiftUI 뷰가 이걸 관찰한다.

import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

final class AppController: ObservableObject {
    let settings = Settings()

    @Published var state: Clicker.State = .idle
    @Published var taps = 0
    @Published var rate: Double = 0
    @Published var statusLine = "대기 중"
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var hotkeyWarning: String?

    /// 포커스 가드를 적용할 수 없을 때(이 앱 자신이 최전면일 때) 쓰는 센티넬.
    private static let guardDisabled = "\u{0}disabled"

    private lazy var clicker: Clicker = {
        let c = Clicker { pt, hold in SystemTap.post(at: pt, holdMs: hold) }
        c.onStateChange = { [weak self] s in self?.handleStateChange(s) }
        c.onTick = { [weak self] taps, rate in
            self?.taps = taps
            self?.rate = rate
        }
        c.onStop = { [weak self] reason in self?.handleStop(reason) }
        return c
    }()

    private var focusTimer: Timer?
    private var lockedBundleID: String?
    private var cursorOrigin: CGPoint?

    private var ownBundleID: String {
        Bundle.main.bundleIdentifier ?? "com.ssu.tapper"
    }

    // MARK: - 수명주기

    func installHotKeys() {
        var failed: [String] = []
        let center = HotKeyCenter.shared

        if !center.register(.capture, handler: { [weak self] in self?.captureTarget() }) {
            failed.append(HotKey.capture.label)
        }
        if !center.register(.toggle, handler: { [weak self] in self?.toggle() }) {
            failed.append(HotKey.toggle.label)
        }
        if !center.register(.panic, handler: { [weak self] in self?.panicStop() }) {
            failed.append(HotKey.panic.label)
        }

        if !failed.isEmpty {
            hotkeyWarning = "핫키 \(failed.joined(separator: ", ")) 등록 실패 — 다른 앱이 선점했습니다"
        }
    }

    // MARK: - 동작

    /// 커서가 놓인 지점을 대상으로 저장한다. 미러링 창에서 포커스를 뺄 필요가 없다.
    func captureTarget() {
        settings.captureTarget(SystemTap.cursorLocation())
        statusLine = "좌표 저장 (\(Int(settings.targetX)), \(Int(settings.targetY)))"
        NSSound(named: "Tink")?.play()
    }

    func toggle() {
        guard ensureReady() else { return }
        if clicker.isActive {
            clicker.stop(reason: .manual)
        } else {
            cursorOrigin = SystemTap.cursorLocation()
            clicker.start(config: settings.makeConfig())
        }
    }

    func panicStop() {
        guard clicker.isActive else { return }
        clicker.stop(reason: .manual)
        NSSound(named: "Basso")?.play()
    }

    /// 성공할 수 없는 상태에서 시작해서 "안 된다"로 오해하게 만들지 않는다.
    private func ensureReady() -> Bool {
        axTrusted = AXIsProcessTrusted()
        guard axTrusted else {
            statusLine = "손쉬운 사용 권한이 없어 시작할 수 없습니다"
            NSSound(named: "Basso")?.play()
            return false
        }
        guard settings.hasTarget else {
            statusLine = "먼저 좌표를 지정하세요 (\(HotKey.capture.label))"
            NSSound(named: "Basso")?.play()
            return false
        }
        return true
    }

    func requestAXPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAXSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func refreshTrust() {
        axTrusted = AXIsProcessTrusted()
    }

    // MARK: - 상태 변화

    private func handleStateChange(_ s: Clicker.State) {
        state = s
        switch s {
        case .waiting:
            taps = 0
            rate = 0
            statusLine = "\(Int(settings.startDelaySec))초 후 시작 — 대상 창으로 이동하세요"
        case .running:
            statusLine = "연타 중"
            startFocusGuard()
        case .idle:
            stopFocusGuard()
        }
    }

    private func handleStop(_ reason: StopReason) {
        stopFocusGuard()
        // 커서를 사용자가 두고 간 자리로 되돌린다. 연타가 커서를 훔쳐가면 안 된다.
        if let origin = cursorOrigin {
            SystemTap.moveCursor(to: origin)
            cursorOrigin = nil
        }
        statusLine = "\(reason.rawValue) · \(taps)회"
        if reason == .focusLost || reason == .hardCap {
            NSSound(named: "Basso")?.play()
        } else {
            NSSound(named: "Pop")?.play()
        }
    }

    // MARK: - 포커스 가드
    //
    // 시작 시점의 최전면 앱에 고정하고, 다른 앱으로 바뀌면 즉시 멈춘다.
    // 미러링 창을 떠난 뒤에도 계속 클릭해서 엉뚱한 창을 난타하는 사고를 막는다.
    // 특정 번들 ID를 하드코딩하지 않으므로 미러링이 아닌 대상에도 그대로 쓸 수 있다.

    private func startFocusGuard() {
        guard settings.guardFocus else { return }
        lockedBundleID = nil
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkFocus()
        }
    }

    private func stopFocusGuard() {
        focusTimer?.invalidate()
        focusTimer = nil
        lockedBundleID = nil
    }

    private func checkFocus() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard let locked = lockedBundleID else {
            // 첫 검사에서 대상을 확정한다.
            if front == ownBundleID {
                // 팝오버에서 시작해 우리 앱이 최전면인 경우. 고정할 대상이 없으므로
                // 이번 실행에는 가드를 적용하지 않는다.
                lockedBundleID = Self.guardDisabled
                statusLine = "연타 중 (포커스 가드 미적용)"
            } else {
                lockedBundleID = front
            }
            return
        }

        guard locked != Self.guardDisabled, front != locked else { return }
        clicker.stop(reason: .focusLost)
    }
}
