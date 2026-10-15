// 사용자 설정. UserDefaults에 즉시 영속화한다.

import CoreGraphics
import Foundation

enum UIMode: String, CaseIterable, Identifiable {
    case toggle, duration, count

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggle: return "토글"
        case .duration: return "시간"
        case .count: return "횟수"
        }
    }

    var hint: String {
        switch self {
        case .toggle: return "다시 누를 때까지 계속 연타합니다."
        case .duration: return "지정한 시간이 지나면 자동으로 멈춥니다."
        case .count: return "지정한 횟수를 채우면 자동으로 멈춥니다."
        }
    }
}

final class Settings: ObservableObject {
    // 하한 2ms는 엔진이 오차 없이 낼 수 있는 한계값이다(ratebench 측정).
    // "이 값이 대상 앱에 반영된다"는 보장이 아니다 — 반영 여부는 대상 앱마다
    // 다르므로, 유실이 생기면 사용자가 간격을 올려 맞춘다.
    static let intervalRange = 2.0...2000.0
    static let holdRange = 1.0...100.0
    static let durationRange = 1.0...3600.0
    static let countRange = 1...100_000

    private let d = UserDefaults.standard

    @Published var targetX: Double { didSet { d.set(targetX, forKey: "targetX") } }
    @Published var targetY: Double { didSet { d.set(targetY, forKey: "targetY") } }
    @Published var hasTarget: Bool { didSet { d.set(hasTarget, forKey: "hasTarget") } }

    @Published var intervalMs: Double {
        didSet {
            // 키보드로 직접 입력받으므로 범위 밖 값이나 NaN이 들어올 수 있다.
            // NaN을 흘리면 1000/간격 계산과 타이머 스케줄이 동시에 깨진다.
            let base = intervalMs.isFinite ? intervalMs.rounded() : 100
            let fixed = base.clamped(to: Settings.intervalRange)
            if fixed != intervalMs { intervalMs = fixed; return }
            // 누름 시간이 간격 이상이면 실효 레이트가 무너진다. 엔진도 방어하지만
            // UI에서 먼저 맞춰둔다.
            if holdMs >= intervalMs { holdMs = max(1, (intervalMs / 3).rounded(.down)) }
            d.set(intervalMs, forKey: "intervalMs")
        }
    }

    @Published var holdMs: Double {
        didSet {
            let clamped = holdMs.clamped(to: Settings.holdRange)
            if clamped != holdMs { holdMs = clamped; return }
            d.set(holdMs, forKey: "holdMs")
        }
    }

    @Published var mode: UIMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var durationSec: Double {
        didSet {
            // 키보드로 직접 입력받으므로 범위 밖 값이나 NaN이 들어올 수 있다.
            // 1초 단위로 정규화한다.
            let base = durationSec.isFinite ? durationSec.rounded() : 30
            let fixed = base.clamped(to: Settings.durationRange)
            if fixed != durationSec { durationSec = fixed; return }
            d.set(durationSec, forKey: "durationSec")
        }
    }

    @Published var countLimit: Int {
        didSet {
            let fixed = countLimit.clamped(to: Settings.countRange)
            if fixed != countLimit { countLimit = fixed; return }
            d.set(countLimit, forKey: "countLimit")
        }
    }
    @Published var startDelaySec: Double { didSet { d.set(startDelaySec, forKey: "startDelaySec") } }
    @Published var guardFocus: Bool { didSet { d.set(guardFocus, forKey: "guardFocus") } }

    init() {
        d.register(defaults: [
            "intervalMs": 100.0,     // Phase 0에서 유실 0으로 확인된 값
            "holdMs": 15.0,
            "mode": UIMode.toggle.rawValue,
            "durationSec": 30.0,
            "countLimit": 100,
            "startDelaySec": 3.0,
            "guardFocus": true,
        ])
        targetX = d.double(forKey: "targetX")
        targetY = d.double(forKey: "targetY")
        hasTarget = d.bool(forKey: "hasTarget")
        intervalMs = d.double(forKey: "intervalMs")
        holdMs = d.double(forKey: "holdMs")
        mode = UIMode(rawValue: d.string(forKey: "mode") ?? "") ?? .toggle
        durationSec = d.double(forKey: "durationSec")
        countLimit = d.integer(forKey: "countLimit")
        startDelaySec = d.double(forKey: "startDelaySec")
        guardFocus = d.bool(forKey: "guardFocus")
    }

    var target: CGPoint { CGPoint(x: targetX, y: targetY) }

    var stopMode: StopMode {
        switch mode {
        case .toggle: return .toggle
        case .duration: return .duration(durationSec)
        case .count: return .count(countLimit)
        }
    }

    func makeConfig() -> ClickerConfig {
        ClickerConfig(point: target,
                      intervalMs: Int(intervalMs),
                      holdMs: Int(holdMs),
                      mode: stopMode,
                      startDelay: startDelaySec)
    }

    func captureTarget(_ pt: CGPoint) {
        targetX = pt.x.rounded()
        targetY = pt.y.rounded()
        hasTarget = true
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, r.lowerBound), r.upperBound)
    }
}

extension Int {
    func clamped(to r: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, r.lowerBound), r.upperBound)
    }
}
