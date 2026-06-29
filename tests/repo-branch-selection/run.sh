#!/usr/bin/env bash
# Golden test — repoBranch fork knob. Asserts `make fork-init` retargets every git-source
# branch ref (Application `targetRevision` + ApplicationSet `targetRevision`/`revision`) to the
# config.yaml `repoBranch`, while leaving chart-version `targetRevision`s and the substring `main`
# inside other tokens (e.g. `domain`) untouched. Idempotent on a second run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NEWB="cloud-proof-xyz"
SCOPE=(clusters platform serving routing workloads)

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git clone -q --local . "$tmp/repo"
cd "$tmp/repo"

perl -pi -e "s|^repoBranch:.*|repoBranch: ${NEWB}|" environments/ai-dev/config.yaml

if ! ./scripts/fork-init.sh >"$tmp/forkinit.log" 2>&1; then
  echo "FAIL fork-init errored"; cat "$tmp/forkinit.log"; exit 1
fi

fail=0
absent() { # desc  cmd...   (PASS when cmd finds nothing)
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL $desc"; fail=1; else echo "OK   $desc"; fi
}

# 1. No git-source branch ref left on the old defaults.
absent "no leftover 'targetRevision: main'" git grep -qE '^[[:space:]]*targetRevision: main$' -- "${SCOPE[@]}"
absent "no leftover 'targetRevision: HEAD'" git grep -qE '^[[:space:]]*targetRevision: HEAD$' -- "${SCOPE[@]}"
absent "no leftover 'revision: HEAD'"       git grep -qE '^[[:space:]]*revision: HEAD$' -- "${SCOPE[@]}"

# 2. The branch refs were retargeted to the new branch.
n="$(git grep -cE "^[[:space:]]*(targetRevision|revision): ${NEWB}\$" -- "${SCOPE[@]}" | awk -F: '{s+=$NF} END{print s+0}')"
if [ "${n:-0}" -ge 50 ]; then echo "OK   retargeted ${n} git-source branch refs -> ${NEWB}"
else echo "FAIL only ${n:-0} refs retargeted (<50)"; fail=1; fi

# 3. Chart-version targetRevisions are NOT branch refs — must survive untouched.
for v in 1.89.2 9.5.21 0.28.3 0.3.0; do
  if git grep -qF "targetRevision: ${v}" -- "${SCOPE[@]}"; then echo "OK   chart version ${v} intact"
  else echo "FAIL chart version ${v} lost"; fail=1; fi
done

# 4. The anchoring holds: `main` inside another token (e.g. `domain`) was not rewritten.
absent "no corrupted 'do${NEWB}' (domain not rewritten)" git grep -qF "do${NEWB}"
if git grep -qF 'ai-platform.wmx.dev' -- "${SCOPE[@]}"; then echo "OK   domain literal intact"
else echo "FAIL domain literal altered"; fail=1; fi

# 5. Idempotent: a second run produces no further change.
git add -A && git -c user.email=t@t -c user.name=t commit -qm snapshot
if ! ./scripts/fork-init.sh >"$tmp/forkinit2.log" 2>&1; then
  echo "FAIL second fork-init errored"; cat "$tmp/forkinit2.log"; exit 1
fi
if git diff --quiet; then echo "OK   idempotent (second run no-op)"
else echo "FAIL second run changed files:"; git --no-pager diff --stat; fail=1; fi

exit "$fail"
