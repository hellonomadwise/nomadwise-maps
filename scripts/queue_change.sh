#!/usr/bin/env bash
# Gets the local commits that are not on GitHub yet ready to be queued
# (docs/AUTO_APPLY.md): prints the checksum and the patch as base64 in
# parts of 6,000 characters, for code_change_begin / _append / _commit
# (or code_change_add when there is one part).
set -euo pipefail
git fetch -q origin
n=$(git rev-list --count origin/main..HEAD)
if [ "$n" = "0" ]; then echo "Nothing to send: no commits ahead of origin/main."; exit 0; fi
if git diff --name-only origin/main HEAD | grep -q '^\.github/'; then
  echo "This touches .github/: those files must be uploaded by hand. Leave them out."; exit 1
fi
tmp=$(mktemp -d)
git format-patch origin/main..HEAD --binary --stdout | gzip -9n > "$tmp/p.gz"
echo "commits: $n"
echo "base: $(git rev-parse origin/main)"
echo "sha256: $(sha256sum "$tmp/p.gz" | cut -d' ' -f1)"
base64 -w0 "$tmp/p.gz" | fold -w 6000 > "$tmp/p.b64"
echo "parts: $(wc -l < "$tmp/p.b64" | tr -d ' ') (plus a last one if it does not end in a new line)"
i=0
while IFS= read -r line || [ -n "$line" ]; do
  i=$((i + 1)); echo "--- part $i"; echo "$line"
done < "$tmp/p.b64"
