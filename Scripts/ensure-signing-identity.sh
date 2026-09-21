#!/usr/bin/env bash
set -euo pipefail

DEFAULT_SIGNING_ROOT="$HOME/Library/Application Support/ClayHub/Signing"
ACTIVE_SIGNING_FILE="$HOME/Library/Application Support/ClayHub/active-signing-directory"
if [ -f "$ACTIVE_SIGNING_FILE" ]; then
    IFS= read -r DEFAULT_SIGNING_ROOT < "$ACTIVE_SIGNING_FILE"
fi
SIGNING_ROOT="${CLAYHUB_SIGNING_DIR:-$DEFAULT_SIGNING_ROOT}"
KEYCHAIN_PATH="$SIGNING_ROOT/ClayHubSigning.keychain-db"
IDENTITY_NAME="ClayHub Local Code Signing"
KEYCHAIN_PASSWORD="clayhub-local-signing"

mkdir -p "$SIGNING_ROOT"
chmod 700 "$SIGNING_ROOT"

identity_hash() {
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
        | awk -v name="$IDENTITY_NAME" 'index($0, "\"" name "\"") { print $2; exit }'
}

add_to_search_list() {
    if security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | grep -Fxq "$KEYCHAIN_PATH"; then
        return
    fi

    existing_keychains=()
    while IFS= read -r keychain; do
        keychain="$(printf '%s' "$keychain" \
            | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
        [ -n "$keychain" ] && existing_keychains+=("$keychain")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "$KEYCHAIN_PATH" "${existing_keychains[@]}"
}

if [ -f "$KEYCHAIN_PATH" ]; then
    if ! security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1; then
        echo "Cannot unlock the ClayHub signing keychain; set CLAYHUB_SIGNING_DIR to a new dedicated directory." >&2
        exit 1
    fi
    existing_hash="$(identity_hash)"
    if [ -n "$existing_hash" ]; then
        add_to_search_list
        printf '%s|%s\n' "$existing_hash" "$KEYCHAIN_PATH"
        exit 0
    fi

    mv "$KEYCHAIN_PATH" "$KEYCHAIN_PATH.invalid.$(date +%s)"
fi

temp_dir="$(mktemp -d /tmp/clayhub-signing.XXXXXX)"
trap 'rm -rf "$temp_dir"' EXIT

openssl req -new -newkey rsa:2048 -x509 -sha256 -days 3650 -nodes \
    -subj "/CN=$IDENTITY_NAME/O=ClayHub Local Development" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$temp_dir/key.pem" \
    -out "$temp_dir/cert.pem" >/dev/null 2>&1

openssl pkcs12 -export \
    -name "$IDENTITY_NAME" \
    -inkey "$temp_dir/key.pem" \
    -in "$temp_dir/cert.pem" \
    -out "$temp_dir/identity.p12" \
    -passout "pass:$KEYCHAIN_PASSWORD" >/dev/null 2>&1

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$temp_dir/identity.p12" \
    -k "$KEYCHAIN_PATH" \
    -P "$KEYCHAIN_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security add-trusted-cert -d -r trustRoot \
    -k "$KEYCHAIN_PATH" "$temp_dir/cert.pem"
chmod 600 "$KEYCHAIN_PATH"

add_to_search_list
created_hash="$(identity_hash)"
if [ -z "$created_hash" ]; then
    echo "Failed to create the ClayHub signing identity." >&2
    exit 1
fi

printf '%s|%s\n' "$created_hash" "$KEYCHAIN_PATH"
