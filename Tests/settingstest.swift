// Settings 정규화 테스트.
//
// 키보드 입력을 받게 되면서 범위 밖 값·소수·NaN이 들어올 수 있다.
// didSet 안에서 자기 값을 재할당하므로 클램프가 멱등하지 않으면 무한 재귀로
// 앱이 멈춘다. 그게 실제로 종료되는지 확인하는 것이 이 테스트의 핵심이다.

import CoreGraphics
import Foundation

var failures = 0

func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("  PASS  \(label)") }
    else { failures += 1; print("  FAIL  \(label)\(detail.isEmpty ? "" : "  — \(detail)")") }
}

@main
struct SettingsTest {
    static func main() {
        print("=== Settings 정규화 테스트 ===")

        let s = Settings()

        print("\n[1] 시간 — 범위 클램프 (1...3600)")
        s.durationSec = 5000
        check(s.durationSec == 3600, "상한 초과 → 3600", "실제 \(s.durationSec)")
        s.durationSec = 0
        check(s.durationSec == 1, "하한 미달 → 1", "실제 \(s.durationSec)")
        s.durationSec = 30
        check(s.durationSec == 30, "범위 내 값은 유지", "실제 \(s.durationSec)")

        print("\n[2] 시간 — 1초 단위 정규화")
        s.durationSec = 2.4
        check(s.durationSec == 2, "2.4 → 2", "실제 \(s.durationSec)")
        s.durationSec = 2.6
        check(s.durationSec == 3, "2.6 → 3", "실제 \(s.durationSec)")

        print("\n[3] 시간 — NaN 방어 (빈 입력란 등)")
        s.durationSec = Double.nan
        check(s.durationSec == 30, "NaN → 기본값 30", "실제 \(s.durationSec)")
        s.durationSec = Double.infinity
        check(s.durationSec.isFinite, "무한대 → 유한값", "실제 \(s.durationSec)")

        print("\n[4] 횟수 — 범위 클램프 (1...100000)")
        s.countLimit = 999_999
        check(s.countLimit == 100_000, "상한 초과 → 100000", "실제 \(s.countLimit)")
        s.countLimit = -5
        check(s.countLimit == 1, "음수 → 1", "실제 \(s.countLimit)")
        s.countLimit = 250
        check(s.countLimit == 250, "범위 내 값은 유지", "실제 \(s.countLimit)")

        print("\n[5] 간격 변경 시 누름 시간 자동 조정")
        s.intervalMs = 5
        check(s.holdMs < s.intervalMs,
              "간격 5ms → 누름이 간격 미만", "간격 \(s.intervalMs) 누름 \(s.holdMs)")
        s.intervalMs = 100
        check(s.holdMs < s.intervalMs,
              "간격 100ms → 누름이 간격 미만", "간격 \(s.intervalMs) 누름 \(s.holdMs)")

        print("\n[6] 하한 2ms에서도 누름 시간이 간격 미만")
        // 2ms에서 (2/3).rounded(.down) == 0 이므로 max(1, 0) == 1 이 되어야 한다.
        // 이게 깨지면 hold >= interval이 되어 실효 레이트가 조용히 무너진다.
        for iv in [2.0, 3.0, 4.0, 5.0] {
            s.intervalMs = iv
            check(s.holdMs < s.intervalMs && s.holdMs >= 1,
                  "간격 \(Int(iv))ms → 누름 \(Int(s.holdMs))ms",
                  "간격 \(s.intervalMs) 누름 \(s.holdMs)")
        }
        s.intervalMs = 2
        check(s.makeConfig().holdMs < s.makeConfig().intervalMs,
              "makeConfig()도 hold < interval 유지",
              "config hold \(s.makeConfig().holdMs) interval \(s.makeConfig().intervalMs)")

        print("\n[7] 간격 하한 클램프 (2ms)")
        s.intervalMs = 1
        check(s.intervalMs == 2, "1ms → 2ms로 클램프", "실제 \(s.intervalMs)")
        s.intervalMs = 0
        check(s.intervalMs == 2, "0ms → 2ms로 클램프", "실제 \(s.intervalMs)")

        print("\n[8] 간격 — 키보드 입력 방어")
        // 입력란을 비우면 NaN이 들어올 수 있다. 흘리면 1000/간격 계산과
        // 타이머 스케줄이 동시에 깨진다.
        s.intervalMs = Double.nan
        check(s.intervalMs == 100, "NaN → 기본값 100", "실제 \(s.intervalMs)")
        s.intervalMs = Double.infinity
        check(s.intervalMs.isFinite, "무한대 → 유한값", "실제 \(s.intervalMs)")
        s.intervalMs = 7.4
        check(s.intervalMs == 7, "7.4 → 7 (1ms 단위)", "실제 \(s.intervalMs)")
        s.intervalMs = 7.6
        check(s.intervalMs == 8, "7.6 → 8 (1ms 단위)", "실제 \(s.intervalMs)")
        s.intervalMs = 99999
        check(s.intervalMs == 2000, "상한 초과 → 2000", "실제 \(s.intervalMs)")
        // NaN 경로를 지난 뒤에도 누름 시간 불변식이 유지되어야 한다.
        s.intervalMs = Double.nan
        check(s.holdMs < s.intervalMs, "NaN 복구 후에도 누름 < 간격",
              "간격 \(s.intervalMs) 누름 \(s.holdMs)")

        print("\n[9] 모드별 StopMode 변환")
        s.mode = .duration; s.durationSec = 45
        check(s.stopMode == .duration(45), "duration(45)", "실제 \(s.stopMode)")
        s.mode = .count; s.countLimit = 77
        check(s.stopMode == .count(77), "count(77)", "실제 \(s.stopMode)")
        s.mode = .toggle
        check(s.stopMode == .toggle, "toggle", "실제 \(s.stopMode)")

        print("\n=========================")
        print(failures == 0 ? "전체 통과 (무한 재귀 없음)" : "실패 \(failures)건")
        exit(failures == 0 ? 0 : 1)
    }
}
