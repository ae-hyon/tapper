#!/usr/bin/env bash
# 코드 서명용 자체 서명 인증서를 로그인 키체인에 만든다. 한 번만 실행하면 된다.
#
# 왜 필요한가:
#   ad-hoc 서명(codesign -s -)은 designated requirement가 바이너리 해시(cdhash)로
#   고정된다. 재빌드하면 해시가 바뀌므로 손쉬운 사용 권한이 매번 깨진다.
#   인증서로 서명하면 DR이 "번들 ID + 인증서 해시"가 되어 권한이 유지된다.
#
# macOS에서 걸리는 함정 두 개를 이 스크립트가 처리한다:
#   1. OpenSSL 3는 비공개 키를 PKCS#8로 쓰지만 security는 전통적 RSA 포맷만 읽는다
#   2. OpenSSL 3의 PKCS#12는 AES/SHA-256을 쓰는데 security가 못 읽는다
#      → p12를 거치지 않고 키와 인증서를 따로 가져온다

set -euo pipefail

CN="Tapper Local Dev"
KC="$HOME/Library/Keychains/login.keychain-db"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CN\""; then
    echo "이미 존재합니다:"
    security find-identity -p codesigning | grep "\"$CN\""
    exit 0
fi

cat > "$TMP/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CN
[v3]
basicConstraints   = critical,CA:FALSE
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
CNF

echo "==> 키 + 자체 서명 인증서 생성 (10년)"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$TMP/key_pkcs8.pem" -out "$TMP/cert.pem" -config "$TMP/req.cnf" 2>/dev/null

echo "==> 전통적 RSA 포맷으로 변환"
openssl rsa -in "$TMP/key_pkcs8.pem" -traditional -out "$TMP/key.pem" 2>/dev/null

echo "==> 로그인 키체인에 가져오기"
security import "$TMP/key.pem"  -k "$KC" -t priv -f openssl -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$KC" -t cert -f openssl -T /usr/bin/codesign

echo
echo "==> 결과"
security find-identity -p codesigning | grep "\"$CN\"" || {
    echo "식별자를 찾을 수 없습니다. 키체인 접근에서 확인하세요."
    exit 1
}

cat <<'MSG'

CSSMERR_TP_NOT_TRUSTED는 자체 서명이라 정상입니다. 서명에는 영향이 없습니다
(신뢰 여부는 Gatekeeper 검증에만 관여합니다).

이제 ./build.sh 가 이 인증서를 자동으로 사용합니다.
처음 서명할 때 "codesign이 키를 사용하려 합니다" 창이 뜨면 '항상 허용'을 누르세요.

기존에 받아둔 권한은 ad-hoc 서명 기준이라 한 번은 초기화해야 합니다:
  tccutil reset Accessibility com.ssu.tapper
MSG
