#!/usr/bin/env bash
# Xcode.app 없이 CLT의 swiftc만으로 .app 번들을 조립한다.
#
# 손쉬운 사용 권한은 코드 서명에 묶이므로 ad-hoc 서명을 고정 식별자로 넣는다.
# 그래도 재빌드하면 권한이 떨어질 수 있다 — 그때는 시스템 설정에서
# Tapper를 제거하고 다시 추가해야 한다.

set -euo pipefail
cd "$(dirname "$0")"

APP="build/Tapper.app"
BUNDLE_ID="com.ssu.tapper"
TARGET="arm64-apple-macos13.0"

mkdir -p build

# --- 1. 엔진 테스트 (실패하면 앱을 빌드하지 않는다) ---
if [[ "${1:-}" != "--skip-tests" ]]; then
    echo "==> 엔진 테스트"
    swiftc -O -target "$TARGET" Sources/Clicker.swift Tests/enginetest.swift \
        -o build/enginetest
    ./build/enginetest
    echo

    echo "==> 설정 정규화 테스트"
    swiftc -O -target "$TARGET" Sources/Clicker.swift Sources/Settings.swift \
        Tests/settingstest.swift -o build/settingstest
    ./build/settingstest
    echo
fi

# --- 1b. 레이트 벤치 (엔진 스케줄링 한계 측정, 수동 실행용) ---
echo "==> ratebench 빌드"
swiftc -O -target "$TARGET" Sources/Clicker.swift Tests/ratebench.swift \
    -o build/ratebench
echo "    ./build/ratebench 로 실행"
echo

# --- 2. Phase 0 검증 도구 ---
echo "==> tapprobe"
swiftc -O -target "$TARGET" tapprobe.swift -o tapprobe

# --- 3. 앱 번들 ---
echo "==> Tapper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tapper</string>
    <key>CFBundleDisplayName</key><string>Tapper</string>
    <key>CFBundleExecutable</key><string>Tapper</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 메뉴바 전용: Dock 아이콘과 앱 전환기에서 숨긴다 -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

swiftc -O -target "$TARGET" \
    Sources/Clicker.swift \
    Sources/Settings.swift \
    Sources/HotKeys.swift \
    Sources/AppController.swift \
    Sources/PopoverView.swift \
    Sources/main.swift \
    -framework AppKit -framework SwiftUI -framework Carbon \
    -o "$APP/Contents/MacOS/Tapper"

# 자체 서명 인증서가 있으면 그걸 쓴다. ad-hoc 서명은 designated requirement가
# cdhash로 고정되므로 재빌드마다 손쉬운 사용 권한이 깨진다. 인증서 기반 서명은
# DR이 "번들 ID + 인증서 해시"가 되어 바이너리가 바뀌어도 권한이 유지된다.
SIGN_ID=$(security find-identity -p codesigning 2>/dev/null \
          | awk '/"Tapper Local Dev"/ {print $2; exit}')

if [[ -n "$SIGN_ID" ]]; then
    echo "    서명: Tapper Local Dev ($SIGN_ID)"
    codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/    /'
else
    echo "    경고: 자체 서명 인증서가 없어 ad-hoc으로 서명합니다."
    echo "          재빌드마다 손쉬운 사용 권한이 깨집니다. ./setup-signing.sh 를 실행하세요."
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/    /'
fi

echo
echo "빌드 완료: $APP"
echo
echo "실행:  open $APP"
echo "핫키:  ⌥⌘C 좌표지정 · ⌥⌘S 시작/정지 · ⌥⌘. 긴급정지"
echo
echo "첫 실행 시 손쉬운 사용 권한을 요청합니다. 권한을 준 뒤에는"
echo "앱을 완전히 종료하고(메뉴바 > 종료) 다시 실행해야 반영됩니다."
