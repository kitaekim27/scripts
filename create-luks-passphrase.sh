#!/bin/sh
# concatenate the key in TPM and the passphrase to generate LUKS passphrase
set -o errexit -o nounset -o noglob

passphrase="$1"

tmpdir=$(mktemp -d)

tpm2 startauthsession \
    --policy-session \
    --session="$tmpdir/session.bin"

tpm2 policypcr \
    --quiet \
    --session="$tmpdir/session.bin" \
    --pcr-list="sha256:0,2,4,8,9"

# unseal a key from the first not-reserved persistent object handle (0x81018000)
key=$(tpm2 unseal \
    --auth="session:$tmpdir/session.bin" \
    --object-context="0x81018000" | base64)

key_digest=$(echo "$key" | base64 -d | sha256sum | awk '{print $1}')
passphrase_digest=$(echo "$passphrase" | sha256sum | awk '{print $1}')

concat="$key_digest$passphrase_digest"
echo "$concat" | xxd -revert -plain | sha256sum | awk '{print "result =", $1}'
