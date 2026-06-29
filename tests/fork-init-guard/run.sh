#!/usr/bin/env bash
# Golden test — fork-init pre-flight consistency guard. Asserts two things on throwaway clones (no
# live cluster): (a) on a consistent template tree where a real domain replacement is due, fork-init
# proceeds and rewrites the domain; (b) when one cross-check anchor is hand-edited to a different
# domain while the discovery anchor still holds the template value (a replace is still due), fork-init
# aborts non-zero with the guard message naming the disagreeing file, instead of silently leaving the
# lagging files wrong. Domain-independent: the old domain is discovered the same way the script does.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NEW="forktest-guard.example"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

# (a) consistent template tree: replacement due, every anchor agrees -> proceed and rewrite.
git clone -q --local . "$tmp/a"
( cd "$tmp/a"
  perl -pi -e "s|^domain:.*|domain: \"${NEW}\"|" environments/ai-dev/config.yaml
  if ! ./scripts/fork-init.sh >"$tmp/a.log" 2>&1; then
    echo "FAIL (a) consistent tree aborted:"; cat "$tmp/a.log"; exit 1; fi
  if git grep -qF "admin@${NEW}" -- routing/edge/cluster-issuer.yaml; then
    echo "OK   (a) consistent tree: domain rewritten to ${NEW}"
  else
    echo "FAIL (a) domain not rewritten"; cat "$tmp/a.log"; exit 1; fi
) || fail=1

# (b) one cross-check anchor hand-edited to a different domain while a replacement is still due -> abort.
git clone -q --local . "$tmp/b"
( cd "$tmp/b"
  old="$(awk -F'admin@' '/email: admin@/{gsub(/[ \t"]/,"",$2);print $2;exit}' routing/edge/cluster-issuer.yaml)"
  perl -pi -e "s|^domain:.*|domain: \"${NEW}\"|" environments/ai-dev/config.yaml
  old="$old" perl -pi -e 'BEGIN{$o=$ENV{old}} s/\Q$o\E/hand-edited.example/g' bootstrap/argo-cd/values.yaml
  if ./scripts/fork-init.sh >"$tmp/b.log" 2>&1; then
    echo "FAIL (b) inconsistent tree did not abort:"; cat "$tmp/b.log"; exit 1; fi
  if grep -q "inconsistent pre-fork template" "$tmp/b.log" \
     && grep -q "bootstrap/argo-cd/values.yaml" "$tmp/b.log"; then
    echo "OK   (b) inconsistent tree aborted with guard message naming the file"
  else
    echo "FAIL (b) aborted without the expected guard message:"; cat "$tmp/b.log"; exit 1; fi
) || fail=1

exit "$fail"
