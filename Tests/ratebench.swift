// 엔진의 스케줄링 한계 측정.
//
// "클릭 최소 단위를 20ms 미만으로 낼 수 있는가"에서 '엔진' 층만 떼어내 재는 도구다.
// 미러링 전송과 iOS 터치 처리는 여기서 측정할 수 없다 — 그 둘은 실기기 테스트가 필요하다.
//
// 두 조건으로 돌린다:
//   A. 누름 0ms  — 타이머 스케줄링 자체의 천장
//   B. 누름 있음 — 실제 동작 모델. postTap이 down→usleep(hold)→up으로
//                 타이머 핸들러를 블로킹하므로 간격을 잡아먹는다.

import CoreGraphics
import Dispatch
import Foundation

final class Recorder {
    private let lock = NSLock()
    private var stamps: [UInt64] = []
    private let holdUs: UInt32

    init(holdMs: Int) { holdUs = UInt32(holdMs) * 1000 }

    /// 실제 SystemTap.post와 같은 블로킹 특성을 재현한다.
    func sink(_ pt: CGPoint, _ hold: Int) {
        let t = DispatchTime.now().uptimeNanoseconds
        lock.lock(); stamps.append(t); lock.unlock()
        if holdUs > 0 { usleep(holdUs) }
    }

    /// 연속 탭 사이 간격(ms) 목록.
    var gapsMs: [Double] {
        lock.lock(); defer { lock.unlock() }
        guard stamps.count >= 2 else { return [] }
        return (1..<stamps.count).map {
            Double(stamps[$0] - stamps[$0 - 1]) / 1_000_000
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return stamps.count }
}

func measure(targetMs: Int, holdMs: Int, taps: Int) -> (mean: Double, max: Double, misses: Int, rate: Double) {
    let rec = Recorder(holdMs: holdMs)
    let c = Clicker(tapSink: rec.sink)
    let sem = DispatchSemaphore(value: 0)
    c.onStop = { _ in sem.signal() }
    c.start(config: ClickerConfig(point: .zero, intervalMs: targetMs, holdMs: holdMs,
                                  mode: .count(taps), startDelay: 0))
    _ = sem.wait(timeout: .now() + 60)

    let gaps = rec.gapsMs
    guard !gaps.isEmpty else { return (0, 0, 0, 0) }
    let mean = gaps.reduce(0, +) / Double(gaps.count)
    // 목표의 1.5배를 넘은 간격은 사실상 틱을 놓친 것으로 본다.
    let misses = gaps.filter { $0 > Double(targetMs) * 1.5 }.count
    return (mean, gaps.max() ?? 0, misses, 1000 / mean)
}

@main
struct RateBench {
    static func main() {
        DispatchQueue.global().async {
            let targets = [20, 15, 10, 8, 5, 3, 2, 1]
            let taps = 200

            for (title, holdFor) in [
                ("A. 누름 0ms — 타이머 스케줄링 천장", { (_: Int) -> Int in 0 }),
                ("B. 누름 있음 — 실제 동작 모델", { (i: Int) -> Int in max(1, i / 3) }),
            ] {
                print("\n=== \(title) ===")
                print(String(format: "%-8@ %-8@ %-11@ %-10@ %-8@ %@",
                             "목표" as NSString, "누름" as NSString,
                             "실측평균" as NSString, "최대" as NSString,
                             "놓침" as NSString, "실효레이트" as NSString))
                for t in targets {
                    let hold = holdFor(t)
                    let r = measure(targetMs: t, holdMs: hold, taps: taps)
                    let flag = r.mean > Double(t) * 1.25 ? "  <-- 목표 미달" : ""
                    print(String(format: "%-8@ %-8@ %-11@ %-10@ %-8@ %.0f tap/s%@",
                                 "\(t)ms" as NSString,
                                 "\(hold)ms" as NSString,
                                 String(format: "%.2fms", r.mean) as NSString,
                                 String(format: "%.1fms", r.max) as NSString,
                                 "\(r.misses)/\(taps - 1)" as NSString,
                                 r.rate,
                                 flag as NSString))
                }
            }
            print("\n주: '놓침'은 간격이 목표의 1.5배를 넘은 횟수.")
            exit(0)
        }
        dispatchMain()
    }
}
