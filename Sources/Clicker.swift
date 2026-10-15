// 코어 연타 엔진.
//
// 탭 발행부를 주입받으므로 실제 클릭 없이 틱 수와 간격 정확도를 테스트할 수 있다.
// NSWorkspace 같은 UI 의존성은 일부러 넣지 않았다 — 포커스 감시는 앱 레이어 담당.

import CoreGraphics
import Dispatch
import Foundation

/// 정지 조건. 사용자가 고르는 "모드"에 대응한다.
enum StopMode: Equatable {
    case toggle                    // 수동 정지까지 (하드 캡은 여전히 적용)
    case duration(TimeInterval)    // 지정 시간 경과 후 자동 정지
    case count(Int)                // 지정 횟수 후 자동 정지
}

/// 왜 멈췄는지 UI에 보여주기 위해 구분한다. "그냥 멈춤"은 디버깅이 안 된다.
enum StopReason: String {
    case manual = "수동 정지"
    case completed = "완료"
    case hardCap = "안전 상한 도달"
    case focusLost = "대상 앱 전환으로 중단"
}

struct ClickerConfig {
    var point: CGPoint
    var intervalMs: Int
    var holdMs: Int = 15
    var mode: StopMode = .toggle
    var startDelay: TimeInterval = 3
}

final class Clicker {
    /// 토글 모드로 켜두고 잊어버려도 영원히 돌지 않게 하는 상한.
    /// 테스트에서 낮춰 검증할 수 있도록 var로 둔다.
    static var hardCapSeconds: TimeInterval = 600

    enum State: Equatable { case idle, waiting, running }

    // 콜백은 전부 메인 큐로 올려서 호출한다. UI가 직접 받아 쓸 수 있도록.
    var onTick: ((_ taps: Int, _ achievedRate: Double) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onStop: ((StopReason) -> Void)?

    private let tapSink: (CGPoint, Int) -> Void
    private let queue = DispatchQueue(label: "tapper.clicker", qos: .userInteractive)

    // 아래 상태는 모두 queue 위에서만 만진다.
    private var timer: DispatchSourceTimer?
    private var state: State = .idle
    private var taps = 0
    private var firstTapAt: DispatchTime?
    private var config: ClickerConfig?

    init(tapSink: @escaping (CGPoint, Int) -> Void) {
        self.tapSink = tapSink
    }

    var isActive: Bool {
        queue.sync { state != .idle }
    }

    var currentState: State {
        queue.sync { state }
    }

    /// 꺼져 있으면 시작, 켜져 있으면 정지. 토글 핫키가 이걸 호출한다.
    func toggle(config: ClickerConfig) {
        if isActive {
            stop(reason: .manual)
        } else {
            start(config: config)
        }
    }

    func start(config: ClickerConfig) {
        queue.async { [weak self] in
            guard let self, self.state == .idle else { return }

            // 누름 시간이 간격 이상이면 타이머 핸들러가 간격 전체를 블로킹해서
            // 실효 레이트가 조용히 무너진다(1ms 벤치에서 관측). 설정 UI가 막지만
            // 엔진에서도 방어한다 — 잘못된 설정이 성능 저하로만 나타나면 진단이 어렵다.
            var cfg = config
            cfg.holdMs = min(cfg.holdMs, max(0, cfg.intervalMs - 1))
            self.config = cfg
            self.taps = 0
            self.firstTapAt = nil
            self.setState(config.startDelay > 0 ? .waiting : .running)

            let interval = max(1, config.intervalMs)
            let t = DispatchSource.makeTimerSource(flags: [.strict], queue: self.queue)
            // .strict가 핵심이다. 없으면 시스템이 타이머를 합쳐서(coalescing)
            // 저전력 상태에서 간격이 멋대로 늘어난다.
            t.schedule(deadline: .now() + config.startDelay,
                       repeating: .milliseconds(interval),
                       leeway: .nanoseconds(0))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    func stop(reason: StopReason) {
        queue.async { [weak self] in
            guard let self, self.state != .idle else { return }
            self.timer?.cancel()
            self.timer = nil
            self.state = .idle
            self.config = nil
            DispatchQueue.main.async {
                self.onStateChange?(.idle)
                self.onStop?(reason)
            }
        }
    }

    // MARK: - 내부

    private func setState(_ new: State) {
        state = new
        DispatchQueue.main.async { self.onStateChange?(new) }
    }

    private func tick() {
        guard state != .idle, let config else { return }

        if state == .waiting { setState(.running) }

        tapSink(config.point, config.holdMs)
        taps += 1

        let now = DispatchTime.now()
        if firstTapAt == nil { firstTapAt = now }

        let elapsed = Double(now.uptimeNanoseconds - firstTapAt!.uptimeNanoseconds) / 1_000_000_000
        // 첫 탭은 경과 0초라 레이트를 낼 수 없다. 2회째부터 의미가 생긴다.
        let rate = elapsed > 0 ? Double(taps - 1) / elapsed : 0
        let snapshot = taps
        DispatchQueue.main.async { self.onTick?(snapshot, rate) }

        switch config.mode {
        case .count(let limit) where taps >= limit:
            finish(.completed)
        case .duration(let seconds) where elapsed >= seconds:
            finish(.completed)
        case .toggle, .count, .duration:
            if elapsed >= Clicker.hardCapSeconds { finish(.hardCap) }
        }
    }

    /// tick() 안에서 호출되므로 이미 queue 위다. stop()의 async 재진입을 피한다.
    private func finish(_ reason: StopReason) {
        timer?.cancel()
        timer = nil
        state = .idle
        config = nil
        DispatchQueue.main.async {
            self.onStateChange?(.idle)
            self.onStop?(reason)
        }
    }
}

/// 실제 화면에 탭을 쏘는 기본 구현. 테스트에서는 이걸 쓰지 않는다.
enum SystemTap {
    static func post(at pt: CGPoint, holdMs: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                           mouseCursorPosition: pt, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                         mouseCursorPosition: pt, mouseButton: .left)
        // clickState를 세우지 않으면 클릭으로 인식하지 않는 앱이 있다.
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)

        down?.post(tap: .cghidEventTap)
        if holdMs > 0 { usleep(UInt32(holdMs) * 1000) }
        up?.post(tap: .cghidEventTap)
    }

    static func moveCursor(to pt: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: .mouseMoved, mouseCursorPosition: pt,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
