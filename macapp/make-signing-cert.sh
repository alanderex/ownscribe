#!/usr/bin/env bash
# One-time setup: create a STABLE self-signed code-signing identity in your login
# keychain so Ownscribe.app keeps the same code identity across rebuilds.
#
# Why: with the default ad-hoc signing, every `build-app.sh` produces a new code
# hash, so macOS treats the rebuilt app as "new" and its Screen Recording /
# Microphone TCC grants reset — you'd re-approve after every build. A stable
# self-signed identity gives the app a constant designated requirement, so the
# grants persist.
#
# This creates a local-only self-signed cert and imports it so codesign can use it
# without prompting. Safe to re-run: it no-ops if the identity already exists.
# To remove later: open Keychain Access, find "Ownscribe Local Signing", delete it.
set -euo pipefail

IDENTITY="Ownscribe Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
HERE="$(cd "$(dirname "$0")" && pwd)"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Signing identity \"$IDENTITY\" already exists. Nothing to do."
  echo "Build with: bash \"$HERE/build-app.sh\""
  exit 0
fi

echo "Creating self-signed code-signing identity: \"$IDENTITY\""
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
P12_PASS="ownscribe"   # protects only the temporary .p12 (lives in $tmp, deleted on exit)

cat > "$tmp/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[dn]
CN = Ownscribe Local Signing
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.cnf"

# OpenSSL 3.x writes a PKCS#12 MAC/cipher that Apple's `security` can't read; -legacy
# restores compatible algorithms (LibreSSL has no -legacy and is already fine). A
# non-empty password is also required — empty-password p12 MACs fail to verify.
P12_LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then P12_LEGACY="-legacy"; fi
openssl pkcs12 -export $P12_LEGACY -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -out "$tmp/identity.p12" -name "$IDENTITY" -passout "pass:$P12_PASS"

# -A lets codesign use the key without a per-build keychain prompt (local dev cert).
security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A

# Verify codesign can actually use it. (An untrusted self-signed cert signs fine, but
# `security find-identity -v` hides it — so we confirm by signing a throwaway file.)
cp /usr/bin/true "$tmp/verify"
if codesign --force --sign "$IDENTITY" "$tmp/verify" >/dev/null 2>&1; then
  echo "Verified: \"$IDENTITY\" is ready for code signing."
else
  echo "Error: identity imported but codesign could not use it." >&2
  exit 1
fi

echo
echo "Done. Next:"
echo "  1) bash \"$HERE/build-app.sh\"   # now signs with \"$IDENTITY\""
echo "  2) Re-grant Screen Recording for Ownscribe ONCE (its identity changed from ad-hoc);"
echo "     after that the grant persists across rebuilds."
