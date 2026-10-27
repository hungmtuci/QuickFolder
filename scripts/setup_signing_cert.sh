#!/bin/bash
set -euo pipefail

CERT_NAME="QuickFolder Developer"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✓ Chứng chỉ '$CERT_NAME' đã tồn tại trong Keychain!"
    exit 0
fi

echo "==> Đang tạo chứng chỉ ký số nội bộ '$CERT_NAME' để giữ quyền Accessibility qua các lần cập nhật..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/cert.conf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_code_sign
prompt = no

[ req_distinguished_name ]
CN = $CERT_NAME
O = QuickFolder Local

[ v3_code_sign ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP_DIR/key.pem" \
    -out "$TMP_DIR/cert.pem" \
    -days 3650 \
    -config "$TMP_DIR/cert.conf" 2>/dev/null

openssl pkcs12 -export -legacy \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/cert.p12" \
    -passout pass:quickfolder 2>/dev/null || \
openssl pkcs12 -export \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/cert.p12" \
    -passout pass:quickfolder 2>/dev/null

LOGIN_KEYCHAIN="$(security login-keychain | tr -d '"' | xargs)"
security import "$TMP_DIR/cert.p12" -k "$LOGIN_KEYCHAIN" -P "quickfolder" -T /usr/bin/codesign

echo "✓ Đã nhập '$CERT_NAME' vào Keychain ($LOGIN_KEYCHAIN)."
echo "  (Nếu muốn đặt Always Trust, mở Keychain Access -> tìm '$CERT_NAME' -> Get Info -> Trust -> Code Signing: Always Trust)"
