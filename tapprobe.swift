// tapprobe — Phase 0 검증 도구
// iPhone 미러링 창에 합성 클릭이 실제로 전달되는지, 최대 몇 tap/s까지
// 유실 없이 들어가는지 측정한다. 본 앱의 코어 엔진 프로토타입 역할도 한다.

import AppKit
import CoreGraphics

let MAX_COUNT = 200          // 폭주 방지 하드 캡
let LEAD_IN_SECONDS = 3      // 포커스 옮길 시간
let CAPTURE_SECONDS = 5      // here 모드에서 커서를 옮길 시간

func usage() {
    print("""
    tapprobe — 좌표 탭 검증 도구

    사용법:
      tapprobe here <count> <intervalMs> [holdMs]
          \(CAPTURE_SECONDS)초 카운트다운 후 '그 순간의 커서 위치'를 대상으로
          count회 탭한다. 좌표를 옮겨 적는 왕복이 없어 가장 편하다.
          예시: tapprobe here 9 100

      tapprobe tap <x> <y> <count> <intervalMs> [holdMs]
          좌표를 명시해 탭한다. 같은 지점을 반복 측정할 때 쓴다.
          예시: tapprobe tap 890 619 9 100

      tapprobe point      현재 커서 좌표 출력
      tapprobe front      최전면 앱 출력 (미러링 포커스 확인용)
      tapprobe ax         손쉬운 사용 권한 보유 여부 출력

    공통: holdMs 생략 시 간격의 1/3 (최대 15ms) · count 최대 \(MAX_COUNT)
          종료 후 커서 원위치 복원
    """)
}

/// 실패 원인을 stderr에 명시하고 종료한다. usage()만 띄우면 원인이 묻힌다.
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("오류: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

/// 권한이 없으면 CGEvent는 조용히 버려진다. 성공할 수 없는 테스트를
/// 돌려서 "클릭이 안 된다"로 오진하게 만드는 것보다 여기서 멈추는 게 낫다.
func requireAXTrust() {
    guard !AXIsProcessTrusted() else { return }
    fail("""
    손쉬운 사용(Accessibility) 권한이 없습니다. 권한 없이는 클릭이
    전송되지 않고 조용히 무시되므로 테스트가 무의미합니다.

      1. 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용
      2. 이 명령을 실행한 터미널 앱을 추가하고 켜기
      3. 터미널을 완전 종료(⌘Q) 후 재실행
      4. ./tapprobe ax  →  granted 확인
    """)
}

/// 현재 커서 위치를 CG 전역 좌표(좌상단 원점)로 반환.
/// NSEvent.mouseLocation은 좌하단 원점이라 변환이 필요하므로 CGEvent를 쓴다.
func cursorLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

func moveCursor(to pt: CGPoint) {
    CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .mouseMoved, mouseCursorPosition: pt,
            mouseButton: .left)?.post(tap: .cghidEventTap)
}

func postTap(at pt: CGPoint, holdMs: Int) {
    let src = CGEventSource(stateID: .hidSystemState)

    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                       mouseCursorPosition: pt, mouseButton: .left)
    let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                     mouseCursorPosition: pt, mouseButton: .left)

    // clickState를 1로 세팅하지 않으면 앱이 클릭으로 인식하지 않는 경우가 있다.
    down?.setIntegerValueField(.mouseEventClickState, value: 1)
    up?.setIntegerValueField(.mouseEventClickState, value: 1)

    down?.post(tap: .cghidEventTap)
    if holdMs > 0 { usleep(UInt32(holdMs) * 1000) }
    up?.post(tap: .cghidEventTap)
}

struct TapParams {
    let count: Int
    let intervalMs: Int
    let holdMs: Int
}

/// count / intervalMs / [holdMs] 세 인자를 공통으로 파싱한다.
func parseParams(_ args: [String], cmd: String, example: String) -> TapParams {
    guard args.count >= 2 else {
        fail("""
        \(cmd)은 인자가 최소 2개 필요합니다: <count> <intervalMs> [holdMs]
          받은 인자: \(args.count)개 \(args)
          예시: tapprobe \(example)
        """)
    }
    guard let count = Int(args[0]) else { fail("count를 숫자로 읽을 수 없습니다: '\(args[0])'") }
    guard let intervalMs = Int(args[1]) else { fail("intervalMs를 숫자로 읽을 수 없습니다: '\(args[1])'") }

    // 누름 시간을 생략하면 간격에 맞춰 자동으로 정한다. 15ms 고정으로 두면
    // 저간격 테스트가 "intervalMs는 holdMs보다 커야 합니다"로 막힌다.
    // 앱의 Settings와 같은 규칙(간격의 1/3, 최대 15ms)을 쓴다.
    var holdMs = min(15, max(1, intervalMs / 3))
    if args.count >= 3 {
        guard let h = Int(args[2]) else { fail("holdMs를 숫자로 읽을 수 없습니다: '\(args[2])'") }
        holdMs = h
    }

    guard count > 0, count <= MAX_COUNT else {
        fail("count는 1~\(MAX_COUNT) 범위여야 합니다 (받음: \(count))")
    }
    guard intervalMs > holdMs else {
        fail("intervalMs(\(intervalMs))는 holdMs(\(holdMs))보다 커야 합니다")
    }
    return TapParams(count: count, intervalMs: intervalMs, holdMs: holdMs)
}

func performTaps(target: CGPoint, params: TapParams) {
    let origin = cursorLocation()
    let rate = 1000.0 / Double(params.intervalMs)
    print("""

    대상 (\(Int(target.x)), \(Int(target.y))) · \(params.count)회 \
    · 간격 \(params.intervalMs)ms · 누름 \(params.holdMs)ms
    요청 레이트: \(String(format: "%.1f", rate)) tap/s
    """)

    // 첫 탭 전에 커서를 옮겨둔다. 이동 이벤트 없이 down부터 받으면
    // 무시하는 앱이 있다.
    moveCursor(to: target)
    usleep(50_000)

    // 누적 드리프트를 막기 위해 매 틱의 목표 시각을 시작점 기준 절대값으로 계산한다.
    let intervalNs = UInt64(params.intervalMs) * 1_000_000
    let start = DispatchTime.now().uptimeNanoseconds

    for i in 0..<params.count {
        let deadline = start + UInt64(i) * intervalNs
        let now = DispatchTime.now().uptimeNanoseconds
        if deadline > now { usleep(UInt32((deadline - now) / 1000)) }
        postTap(at: target, holdMs: params.holdMs)
    }

    let elapsedSec = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    moveCursor(to: origin)   // 커서 원위치 복원

    print("""

    === 결과 ===
    전송한 탭:   \(params.count)회
    경과 시간:   \(String(format: "%.3f", elapsedSec))초
    실측 레이트: \(String(format: "%.2f", Double(params.count) / elapsedSec)) tap/s

    이제 화면에서 실제로 몇 회가 반영됐는지 확인하세요.
    전송 \(params.count)회 대비 반영 횟수가 Phase 0의 판정 기준입니다.
    """)
}

func countdown(_ seconds: Int, message: String) {
    for i in (1...seconds).reversed() {
        print("  \(i)… \(message)")
        sleep(1)
    }
}

func runHere(_ args: [String]) {
    let params = parseParams(args, cmd: "here", example: "here 9 100")
    requireAXTrust()

    print("""
    \(CAPTURE_SECONDS)초 안에 대상 지점으로 커서를 옮기고 그대로 두세요.
    카운트다운이 끝난 순간의 커서 위치가 대상이 됩니다.

    [정확한 측정을 위해] 미러링 창이 이미 포커스를 가진 상태에서 시작하세요.
    포커스가 없으면 첫 클릭이 창 활성화에 쓰여서 1회 적게 반영될 수 있습니다.
    창을 활성화할 때는 iOS 화면이 아닌 '제목 표시줄'을 클릭하세요.
    """)
    countdown(CAPTURE_SECONDS, message: "대상 지점에 커서 올리기")

    let target = cursorLocation()
    performTaps(target: target, params: params)
}

func runTap(_ args: [String]) {
    guard args.count >= 4 else {
        fail("""
        tap은 인자가 최소 4개 필요합니다: <x> <y> <count> <intervalMs> [holdMs]
          받은 인자: \(args.count)개 \(args)
          예시: tapprobe tap 890 619 9 100
          좌표를 적기 번거로우면 'tapprobe here 9 100'을 쓰세요.
        """)
    }
    guard let x = Double(args[0]) else { fail("x를 숫자로 읽을 수 없습니다: '\(args[0])'") }
    guard let y = Double(args[1]) else { fail("y를 숫자로 읽을 수 없습니다: '\(args[1])'") }
    let params = parseParams(Array(args.dropFirst(2)), cmd: "tap", example: "tap 890 619 9 100")
    requireAXTrust()

    countdown(LEAD_IN_SECONDS, message: "미러링 창 제목 표시줄을 클릭해 포커스를 넘기세요")
    performTaps(target: CGPoint(x: x, y: y), params: params)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { usage(); exit(1) }

// 흔한 오타를 조용히 사용법으로 흘려보내지 않고 짚어준다.
let typos = ["tab": "tap", "taps": "tap", "click": "tap",
             "pos": "point", "position": "point", "p": "point",
             "hear": "here", "her": "here"]

switch cmd {
case "point":
    let p = cursorLocation()
    print("\(Int(p.x)) \(Int(p.y))")
case "front":
    let app = NSWorkspace.shared.frontmostApplication
    print("\(app?.localizedName ?? "?") (bundle: \(app?.bundleIdentifier ?? "?"))")
case "ax":
    print(AXIsProcessTrusted() ? "granted" : "denied")
case "here":
    runHere(Array(argv.dropFirst()))
case "tap":
    runTap(Array(argv.dropFirst()))
case "-h", "--help", "help":
    usage()
default:
    if let suggestion = typos[cmd.lowercased()] {
        fail("'\(cmd)'는 없는 명령입니다. '\(suggestion)'을 의도하셨나요?")
    }
    fail("'\(cmd)'는 없는 명령입니다. 사용 가능: here, tap, point, front, ax")
}
