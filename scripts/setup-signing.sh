#!/bin/bash
# 在项目内创建一个专用钥匙串和自签名代码签名证书。
# 签名身份固定后，重新编译不会让系统把应用当成新应用，屏幕录制等权限只需授权一次。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.signing"
KEYCHAIN="$DIR/jietu-signing.keychain-db"
KC_PASS="jietu-local"
P12_PASS="jietu-local"
NAME="Jietu Local Signing"

if [ -f "$KEYCHAIN" ] && security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "签名证书已存在：$KEYCHAIN"
  exit 0
fi

mkdir -p "$DIR"
cd "$DIR"

cat > openssl.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config openssl.cnf -keyout key.pem -out cert.pem >/dev/null 2>&1
openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12 \
  -passout pass:"$P12_PASS" -name "$NAME" >/dev/null 2>&1

rm -f "$KEYCHAIN"
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import cert.p12 -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null

rm -f key.pem cert.p12 openssl.cnf
echo "已创建签名证书：$NAME"
