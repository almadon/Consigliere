#!/usr/bin/env bash
# Checks the age release pins in windows/bootstrap/bootstrap.ps1 against the project's Sigsum proofs. Run it whenever the age
# version or its checksums are changed, on an admin machine (not on a Windows host: the hosts only compare SHA-256).
#
# For each Windows zip it downloads the zip and its .proof from the GitHub release, verifies the proof with sigsum-verify against
# age's published signing keys (https://github.com/FiloSottile/age/blob/main/SIGSUM.md), then compares the zip's SHA-256 with the
# value pinned in bootstrap.ps1. Needs: curl, sigsum-verify (go install sigsum.org/sigsum-go/cmd/sigsum-verify@v0.13.1), shasum or sha256sum.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../bootstrap/bootstrap.ps1"
command -v sigsum-verify >/dev/null || { echo "ERROR: sigsum-verify not found (see the header of this script)" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

version="$(sed -n "s/^\$AgeVersion = '\(.*\)'/\1/p" "$script")"
[ -n "$version" ] || { echo "ERROR: could not read \$AgeVersion from $script" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# The two signing keys age publishes in SIGSUM.md (verified against that file when this script was written).
cat >"$tmp/age-sigsum-key.pub" <<'KEYS'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM1WpnEswJLPzvXJDiswowy48U+G+G1kmgwUE2eaRHZG
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAz2WM5CyPLqiNjk7CLl4roDXwKhQ0QExXLebukZEZFS
KEYS

rc=0
for arch in amd64 arm64; do
  f="age-v$version-windows-$arch.zip"
  base="https://github.com/FiloSottile/age/releases/download/v$version"
  curl -fsSL -o "$tmp/$f" "$base/$f"; curl -fsSL -o "$tmp/$f.proof" "$base/$f.proof"
  if sigsum-verify -k "$tmp/age-sigsum-key.pub" -P sigsum-generic-2025-1 "$tmp/$f.proof" <"$tmp/$f"; then proof=ok; else proof=FAILED; fi
  got="$(sha "$tmp/$f")"
  # the pin blocks hold PowerShell, sops and age values; take the age one (the first match after $AgeSha256)
  want="$(awk '/^\$AgeSha256/{f=1} f&&/'"$arch"'/{print; exit}' "$script" | sed -n "s/.*'\([0-9a-f]\{64\}\)'.*/\1/p")"
  [ "$got" = "$want" ] && pin=ok || pin="MISMATCH (zip $got, pinned $want)"
  echo "$f: sigsum proof $proof, pin $pin"
  [ "$proof" = ok ] && [ "$pin" = ok ] || rc=1
done
exit $rc
