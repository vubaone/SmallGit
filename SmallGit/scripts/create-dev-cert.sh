#!/usr/bin/env bash
# Create a stable self-signed code-signing certificate for SmallGit
# development. This eliminates the macOS TCC permission re-prompt that
# otherwise fires on every rebuild — ad-hoc codesigning ties Files &
# Folders permissions to the binary's cdhash, which changes every time
# `swift build` runs. A stable cert keeps the identity (and therefore
# the TCC grant) constant across rebuilds.
#
# Idempotent: skips if a cert with the same Common Name already exists.
#
# Usage:
#   scripts/create-dev-cert.sh             # create cert "SmallGit Development"
#   scripts/create-dev-cert.sh "MyName"    # use a custom Common Name
#
# After running this once, scripts/build-app.sh automatically picks up
# the cert and uses it instead of ad-hoc signing. The first build with
# the new cert may prompt for keychain access; click "Always Allow".
set -euo pipefail

CERT_NAME="${1:-SmallGit Development}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-certificate -c "${CERT_NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
  echo "OK: certificate '${CERT_NAME}' already exists in login keychain."
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required but not found on PATH." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Code-signing certs need specific Extended Key Usage; default openssl
# self-signed certs don't include it.
cat > "${TMP}/openssl.cnf" <<EOF
[req]
default_bits       = 2048
prompt             = no
distinguished_name = dn
req_extensions     = v3_req
x509_extensions    = v3_req

[dn]
CN = ${CERT_NAME}

[v3_req]
basicConstraints     = critical, CA:FALSE
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
EOF

echo "[1/3] generating self-signed code-signing cert..."
openssl req -x509 -newkey rsa:2048 \
  -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" \
  -days 3650 -nodes -config "${TMP}/openssl.cnf" >/dev/null 2>&1

echo "[2/3] packaging into PKCS#12..."
openssl pkcs12 -export \
  -out "${TMP}/cert.p12" \
  -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
  -passout pass:smallgit \
  -name "${CERT_NAME}" >/dev/null 2>&1

echo "[3/3] importing into login keychain..."
security import "${TMP}/cert.p12" \
  -k "${KEYCHAIN}" \
  -P smallgit \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

echo ""
echo "OK: certificate '${CERT_NAME}' installed."
echo ""
echo "The first build that uses this cert may prompt for keychain access"
echo "(\"codesign wants to use your private key\"). Click \"Always Allow\"."
echo ""
echo "Now run: ./scripts/build-app.sh --open"
