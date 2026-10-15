// Clicker 엔진 테스트.
//
// 탭 발행부를 가짜로 주입하므로 실제 클릭이나 손쉬운 사용 권한 없이 돌아간다.
// 검증 대상: 틱 수의 정확성, 간격 정확도, 각 정지 모드, 안전 상한.
//
// 빌드: swiftc -O Sources/Clicker.swift Tests/enginetest.swift -o build/enginetest

import CoreGraphics
import Dispatch
import Foundation

var failures = 0

func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }
}

/// 탭 시각을 기록하는 가짜 발행부. 실제로는 아무것도 클릭하지 않는다.
final class TapRecorder {
    private let lock = NSLock()
    private var stamps: [UInt64] = []

    func sink(_ pt: CGPoint, _ holdMs: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock(); stamps.append(now); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return stamps.count }

    /// 연속한 탭 사이 간격의 평균(ms).
    var meanIntervalMs: Double {
        lock.lock(); defer { lock.unlock() }
        guard stamps.count >= 2 else { return 0 }
        let span = Double(stamps.last! - stamps.first!) / 1_000_000
        return span / Double(stamps.count - 1)
    }

    var spanSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard let f = stamps.first, let l = stamps.last else { return 0 }
        return Double(l - f) / 1_000_000_000
    }
}

/// 정지 콜백을 기다린다. 콜백은 메인 큐로 오므로 dispatchMain()이 필요하다.
func waitForStop(_ clicker: Clicker, timeout: TimeInterval) -> StopReason? {
    let sem = DispatchSemaphore(value: 0)
    var reason: StopReason?
    clicker.onStop = { r in
        reason = r
        sem.signal()
    }
    return sem.wait(timeout: .now() + timeout) == .success ? reason : nil
}

let origin = CGPoint(x: 100, y: 100)

func test_countMode() {
    print("\n[1] 횟수 모드 — 정확히 N회 탭하고 멈춘다")
    let rec = TapRecorder()
    let c = Clicker(tapSink: rec.sink)
    let reason = waitForStopAfter(c) {
        c.start(config: ClickerConfig(point: origin, intervalMs: 20, holdMs: 0,
                                      mode: .count(10), startDelay: 0))
    }

    check(rec.count == 10, "탭 10회", "실제 \(rec.count)회")
    check(reason == .completed, "정지 사유 completed", "실제 \(reason?.rawValue ?? "nil")")
    check(!c.isActive, "종료 후 비활성 상태")

    let mean = rec.meanIntervalMs
    check(mean > 14 && mean < 30, "평균 간격 20ms 근처", String(format: "실제 %.1fms", mean))
}

func test_durationMode() {
    print("\n[2] 시간 모드 — 지정 시간 경과 후 멈춘다")
    let rec = TapRecorder()
    let c = Clicker(tapSink: rec.sink)
    let reason = waitForStopAfter(c) {
        c.start(config: ClickerConfig(point: origin, intervalMs: 25, holdMs: 0,
                                      mode: .duration(0.5), startDelay: 0))
    }

    // 0.5초 / 25ms = 약 20회. 타이머 정밀도를 감안해 여유를 둔다.
    check(rec.count >= 15 && rec.count <= 25, "탭 약 20회", "실제 \(rec.count)회")
    check(reason == .completed, "정지 사유 completed", "실제 \(reason?.rawValue ?? "nil")")
    let span = rec.spanSeconds
    check(span >= 0.4 && span <= 0.7, "경과 0.5초 근처", String(format: "실제 %.3f초", span))
}

func test_toggleAndManualStop() {
    print("\n[3] 토글 모드 — 수동 정지까지 계속, 정지 후 탭 없음")
    let rec = TapRecorder()
    let c = Clicker(tapSink: rec.sink)
    c.start(config: ClickerConfig(point: origin, intervalMs: 30, holdMs: 0,
                                  mode: .toggle, startDelay: 0))
    Thread.sleep(forTimeInterval: 0.3)
    check(c.isActive, "0.3초 뒤에도 여전히 동작 중")

    let reason = waitForStopAfter(c) { c.stop(reason: .manual) }
    let atStop = rec.count
    check(reason == .manual, "정지 사유 manual", "실제 \(reason?.rawValue ?? "nil")")
    check(atStop >= 5, "정지 전까지 5회 이상 탭", "실제 \(atStop)회")

    Thread.sleep(forTimeInterval: 0.2)
    check(rec.count == atStop, "정지 후 추가 탭 없음",
          "정지 시 \(atStop)회 → 현재 \(rec.count)회")
}

func test_startDelay() {
    print("\n[4] 시작 지연 — 지연 시간 전에는 탭하지 않는다")
    let rec = TapRecorder()
    let c = Clicker(tapSink: rec.sink)
    c.start(config: ClickerConfig(point: origin, intervalMs: 20, holdMs: 0,
                                  mode: .count(3), startDelay: 0.3))
    Thread.sleep(forTimeInterval: 0.15)
    check(rec.count == 0, "지연 중에는 탭 0회", "실제 \(rec.count)회")

    _ = waitForStop(c, timeout: 2)
    check(rec.count == 3, "지연 후 3회 탭", "실제 \(rec.count)회")
}

func test_hardCap() {
    print("\n[5] 안전 상한 — 토글 모드도 상한에서 강제 종료")
    let saved = Clicker.hardCapSeconds
    Clicker.hardCapSeconds = 0.3
    defer { Clicker.hardCapSeconds = saved }

    let rec = TapRecorder()
    let c = Clicker(tapSink: rec.sink)
    let reason = waitForStopAfter(c) {
        c.start(config: ClickerConfig(point: origin, intervalMs: 20, holdMs: 0,
                                      mode: .toggle, startDelay: 0))
    }
    check(reason == .hardCap, "정지 사유 hardCap", "실제 \(reason?.rawValue ?? "nil")")
    check(!c.isActive, "상한 도달 후 비활성 상태")
}

func test_doubleStartIgnored() {
    print("\n[6] 중복 시작 — 이미 돌고 있으면 두 번째 start는 무시")
    let rec = TapRecorder()
    let c = Clicker(tapSink: rec.sink)
    let cfg = ClickerConfig(point: origin, intervalMs: 25, holdMs: 0,
                            mode: .toggle, startDelay: 0)
    c.start(config: cfg)
    c.start(config: cfg)   // 무시되어야 함. 타이머가 두 개 돌면 레이트가 2배가 된다.
    Thread.sleep(forTimeInterval: 0.3)
    _ = waitForStopAfter(c) { c.stop(reason: .manual) }

    // 0.3초 / 25ms ≈ 12회. 타이머가 둘이면 24회쯤 나온다.
    check(rec.count <= 18, "타이머 중복 실행 없음", "실제 \(rec.count)회 (중복이면 ~24회)")
}


/// 누름 시간이 간격 이상이면 타이머 핸들러가 간격 전체를 블로킹해서
/// 실효 레이트가 조용히 무너진다. 엔진이 이를 클램프하는지 확인한다.
func test_holdClamp() {
    print("\n[7] 누름 시간 클램프 — hold >= interval을 엔진이 막는다")
    let lock = NSLock()
    var seenHolds: [Int] = []
    let c = Clicker { _, hold in
        lock.lock(); seenHolds.append(hold); lock.unlock()
    }
    // 간격 10ms에 누름 50ms라는 모순된 설정을 일부러 넣는다.
    _ = waitForStopAfter(c) {
        c.start(config: ClickerConfig(point: origin, intervalMs: 10, holdMs: 50,
                                      mode: .count(5), startDelay: 0))
    }
    lock.lock(); let holds = seenHolds; lock.unlock()
    check(!holds.isEmpty, "탭이 발생함", "실제 \(holds.count)회")
    check(holds.allSatisfy { $0 < 10 }, "누름 시간이 간격 미만으로 클램프됨",
          "관측된 누름 값 \(Set(holds).sorted())")
}

/// 콜백 등록 경쟁을 피하려고 start/stop 직전에 onStop을 걸어준다.
func waitForStopAfter(_ clicker: Clicker, timeout: TimeInterval = 5,
                      _ action: () -> Void) -> StopReason? {
    let sem = DispatchSemaphore(value: 0)
    var reason: StopReason?
    clicker.onStop = { r in
        reason = r
        sem.signal()
    }
    action()
    return sem.wait(timeout: .now() + timeout) == .success ? reason : nil
}

@main
struct EngineTest {
    // 엔진 콜백이 메인 큐로 오므로, 테스트는 백그라운드에서 돌리고
    // 메인 스레드는 dispatchMain()으로 런루프를 돌려야 한다.
    static func main() {
        DispatchQueue.global().async {
            print("=== Clicker 엔진 테스트 ===")
            test_countMode()
            test_durationMode()
            test_toggleAndManualStop()
            test_startDelay()
            test_hardCap()
            test_doubleStartIgnored()
            test_holdClamp()

            print("\n=========================")
            print(failures == 0 ? "전체 통과" : "실패 \(failures)건")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
