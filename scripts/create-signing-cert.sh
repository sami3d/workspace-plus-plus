#!/bin/sh
# Create the compatibility signing identity that Workspace++ project.yml uses
# (CODE_SIGN_IDENTITY "SpaceRenamer Dev"). The historical name is intentional:
# existing local builds retain the same designated requirement. Required so
# macOS Accessibility
# (TCC) grant survives rebuilds: ad-hoc signing has no stable Designated
# Requirement, so TCC never honors the grant and synthesized desktop switches
# are silently dropped. Run once on a machine/keychain that lacks the identity,
# then `xcodegen generate` and build.
set -e
NAME="SpaceRenamer Dev"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Code-signing identity '$NAME' already present."
  exit 0
fi
OSSL="$(command -v /opt/homebrew/bin/openssl || command -v openssl)"
WORK="$(mktemp -d)"
cleanup() {
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
    rm -r -- "$WORK"
  fi
}
trap cleanup EXIT HUP INT TERM
cat > "$WORK/v3.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
"$OSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/k.pem" -out "$WORK/c.pem" -config "$WORK/v3.cnf"
"$OSSL" pkcs12 -export -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -inkey "$WORK/k.pem" -in "$WORK/c.pem" -out "$WORK/id.p12" -passout pass:srdev -name "$NAME"
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P srdev -A -T /usr/bin/codesign
echo "Created code-signing identity '$NAME'. Now run: xcodegen generate && build."
