#!/usr/bin/env bash
# Tapper 설치 스크립트.
#
# 하는 일:
#   1. 환경 사전 점검 (Apple Silicon / macOS / Xcode CLT)
#   2. 코드 서명용 자체 서명 인증서 생성 (최초 1회)
#   3. 빌드 (테스트 통과 후)
#   4. /Applications 로 설치
#   5. LaunchServices 등록 + 실행
#
# 실패하면 원인을 말하고 멈춘다. 조용히 넘어가서 "안 된다"로 헤매게 하지 않는다.

set -uo pipefail
cd "$(dirname "$0")"

APP_NAME="Tapper.app"
DEST="/Applications/$APP_NAME"
CHECK_ONLY=false
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=true

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
info() { printf "\n\033[1m%s\033[0m\n" "$1"; }

fail() {
    echo
    bad "$1"
    shift
    for line in "$@"; do echo "    $line"; done
    echo
    exit 1
}

# ---------------------------------------------------------------
info "1. 환경 점검"

if [[ "$(uname -m)" != "arm64" ]]; then
    fail "Apple Silicon 맥이 필요합니다 (현재: $(uname -m))" \
         "iPhone 미러링이 Intel 맥에서는 동작하지 않습니다."
fi
ok "Apple Silicon ($(uname -m))"

OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( OS_MAJOR < 13 )); then
    fail "macOS 13 이상이 필요합니다 (현재: $(sw_vers -productVersion))"
fi
ok "macOS $(sw_vers -productVersion)"
if (( OS_MAJOR < 15 )); then
    printf "  \033[33m!\033[0m iPhone 미러링은 macOS 15 이상에서만 동작합니다.\n"
    printf "    앱 자체는 설치되지만 아이폰 대상 연타는 쓸 수 없습니다.\n"
fi

if ! command -v swiftc >/dev/null 2>&1; then
    fail "Xcode Command Line Tools가 필요합니다" \
         "아래 명령을 실행해 설치한 뒤 이 스크립트를 다시 실행하세요:" \
         "" \
         "  xcode-select --install" \
         "" \
         "설치 창이 뜨고 수 GB를 내려받습니다. 완료까지 기다려야 합니다."
fi
ok "swiftc $(swiftc --version 2>/dev/null | head -1 | sed 's/.*version //;s/ .*//')"

if $CHECK_ONLY; then
    info "점검 완료 (--check-only)"
    exit 0
fi

# ---------------------------------------------------------------
info "2. 코드 서명 인증서"

# ad-hoc 서명은 designated requirement가 바이너리 해시로 고정되어 재빌드마다
# 손쉬운 사용 권한이 깨진다. 인증서로 서명해야 권한이 유지된다.
if ! ./setup-signing.sh; then
    fail "인증서 생성에 실패했습니다" \
         "키체인 접근 권한 창이 떴다면 허용한 뒤 다시 실행하세요."
fi

# ---------------------------------------------------------------
info "3. 빌드"

if ! ./build.sh; then
    fail "빌드에 실패했습니다" \
         "위 출력에서 실패한 테스트나 컴파일 오류를 확인하세요."
fi

[[ -d "build/$APP_NAME" ]] || fail "빌드 산출물이 없습니다: build/$APP_NAME"

# ---------------------------------------------------------------
info "4. /Applications 설치"

# 경로가 바뀌면 손쉬운 사용 권한 항목이 대상을 잃는다.
# build/ 에 두고 쓰면 프로젝트 폴더를 옮기는 순간 권한이 깨진다.
echo "  앱을 /Applications 에 설치하면 경로가 고정되어 권한이 안정적으로 유지됩니다."
read -rp "  설치할까요? [Y/n] " answer

if [[ "${answer:-Y}" =~ ^[Nn] ]]; then
    TARGET="$(pwd)/build/$APP_NAME"
    printf "  \033[33m!\033[0m 프로젝트 폴더에서 실행합니다. 폴더를 옮기면 권한을 다시 줘야 합니다.\n"
else
    if [[ -d "$DEST" ]]; then
        # 실행 중이면 교체가 실패하므로 먼저 종료한다.
        pkill -f "$APP_NAME/Contents/MacOS/Tapper" 2>/dev/null && sleep 1
        rm -rf "$DEST" || fail "기존 설치본을 제거할 수 없습니다: $DEST"
    fi
    cp -R "build/$APP_NAME" "$DEST" || fail "복사 실패: $DEST"
    TARGET="$DEST"
    ok "설치: $DEST"
fi

# ---------------------------------------------------------------
info "5. 등록 및 실행"

# 등록하지 않으면 tccutil이 번들 ID를 찾지 못한다.
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[[ -x "$LSREG" ]] && "$LSREG" -f "$TARGET" && ok "LaunchServices 등록"

pkill -f "$APP_NAME/Contents/MacOS/Tapper" 2>/dev/null && sleep 1
open "$TARGET" || fail "앱 실행 실패: $TARGET"
ok "실행됨 — 메뉴바에 커서 아이콘이 나타납니다"

# ---------------------------------------------------------------
cat <<'MSG'

════════════════════════════════════════════════════════════
 설치 완료. 마지막으로 권한을 한 번 줘야 합니다.
════════════════════════════════════════════════════════════

 1. 권한 요청 창이 떴으면 승인하세요.
    안 떴으면 메뉴바 아이콘 클릭 → "권한 요청" 버튼.

 2. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용
    에서 Tapper를 켭니다.

 3. ★ 앱을 반드시 재시작하세요 ★
    실행 중에 권한을 줘도 그 프로세스는 계속 거부됩니다.

       메뉴바 아이콘 → 종료, 그다음 앱을 다시 실행

 4. 메뉴바 아이콘을 눌러 주황색 경고 배너가 사라졌으면 끝입니다.

 사용법:
   ⌥⌘C  커서가 놓인 지점을 대상 좌표로 저장
   ⌥⌘S  연타 시작 / 정지
   ⌥⌘.  긴급 정지

 권한이 없으면 클릭이 조용히 무시되므로, 앱이 시작을 거부하고
 배너로 알려줍니다. 아무 반응이 없으면 3번을 다시 확인하세요.

MSG
