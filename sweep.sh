#!/usr/bin/env bash
# Phase 0 유실률 스윕
#
# iOS 계산기의 '1' 버튼을 9회 탭하면서 간격을 낮춰간다.
# 표시창의 1 개수 = 실제 반영된 탭 수이므로 유실을 정확히 셀 수 있다.
# 이 방식의 실용 상한(= 앱 UI의 간격 하한 기본값)을 찾는 것이 목적이다.

set -uo pipefail
cd "$(dirname "$0")"

INTERVALS=(100 70 50 30 20)
TAPS=9

if [[ ! -x ./tapprobe ]]; then
    echo "tapprobe 바이너리가 없습니다. 먼저 빌드하세요:"
    echo "  swiftc -O tapprobe.swift -o tapprobe"
    exit 1
fi

if [[ "$(./tapprobe ax)" != "granted" ]]; then
    echo "손쉬운 사용 권한이 없습니다 (현재: denied)."
    echo "시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용 에 터미널을 추가하고"
    echo "⌘Q로 완전 종료한 뒤 다시 실행하세요."
    exit 1
fi

cat <<'EOF'
=========================================================
 Phase 0 유실률 스윕
=========================================================
준비:
  1. iPhone 미러링을 켜고 iOS '계산기' 앱을 띄웁니다.
  2. 계산기를 AC로 초기화합니다.
  3. 미러링 창이 측정 중 움직이면 좌표가 틀어집니다. 고정해 두세요.

[주의] 미러링 창에 포커스를 줄 때는 반드시 창의 '제목 표시줄'을
       클릭하세요. iOS 화면 영역을 클릭하면 그 클릭도 탭으로
       들어가서 측정값이 오염됩니다.

EOF

read -rp "계산기 '1' 버튼 위에 커서를 올린 뒤 Enter: " _
COORD=$(./tapprobe point)
X=$(echo "$COORD" | cut -d' ' -f1)
Y=$(echo "$COORD" | cut -d' ' -f2)
echo "대상 좌표: ($X, $Y)"
echo

declare -a RESULTS

for interval in "${INTERVALS[@]}"; do
    echo "---------------------------------------------------------"
    echo " 간격 ${interval}ms  (요청 $(awk "BEGIN{printf \"%.1f\", 1000/$interval}") tap/s)"
    echo "---------------------------------------------------------"
    read -rp "계산기를 AC로 초기화했습니까? Enter를 누르면 3초 뒤 시작: " _

    ./tapprobe tap "$X" "$Y" "$TAPS" "$interval"

    echo
    while true; do
        read -rp "표시창에 1이 몇 개 보입니까? (0-${TAPS}): " observed
        [[ "$observed" =~ ^[0-9]+$ ]] && (( observed <= TAPS )) && break
        echo "  0~${TAPS} 사이의 숫자를 입력하세요."
    done

    RESULTS+=("$interval:$observed")
    lost=$(( TAPS - observed ))
    if (( lost == 0 )); then
        echo "  → 유실 0. 통과"
    else
        echo "  → ${lost}회 유실 ($(awk "BEGIN{printf \"%.0f\", $lost*100/$TAPS}")%)"
    fi
    echo
done

echo "========================================================="
echo " 결과 요약   (전송 ${TAPS}회 기준)"
echo "========================================================="
printf " %-10s %-8s %-8s %-10s %s\n" 간격 반영 유실 유실률 실효레이트
best=""
for r in "${RESULTS[@]}"; do
    interval="${r%%:*}"
    observed="${r##*:}"
    lost=$(( TAPS - observed ))
    pct=$(awk "BEGIN{printf \"%.0f\", $lost*100/$TAPS}")
    eff=$(awk "BEGIN{printf \"%.1f\", $observed*1000/($TAPS*$interval)}")
    printf " %-10s %-8s %-8s %-10s %s tap/s\n" "${interval}ms" "$observed" "$lost" "${pct}%" "$eff"
    (( lost == 0 )) && best="$interval"
done

echo
if [[ -n "$best" ]]; then
    echo "유실 없이 가능한 최소 간격: ${best}ms"
    echo "→ 앱 UI의 간격 하한 기본값으로 이 값을 사용합니다."
else
    echo "모든 간격에서 유실이 발생했습니다."
    echo "→ 미러링이 합성 클릭을 합치고 있습니다. 방식 B(XCUITest)로 전환을 검토하세요."
fi
