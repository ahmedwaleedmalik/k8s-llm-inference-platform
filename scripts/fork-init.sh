#!/usr/bin/env bash
# Propagate fork config from environments/<env>/config.yaml across the repo.
#
# environments/<env>/config.yaml is the single source of fork knobs. After forking,
# edit the repoURL + cluster.projectID there, then run this (`make fork-init`) to
# rewrite every other file that embeds those values. Re-runnable and idempotent:
# the "old" value is discovered from canonical manifests, so editing config.yaml is
# the only manual step. Scope = repoURL + GCP projectID + domain + repoBranch.
set -euo pipefail

# fork-init rewrites only git-tracked files (via `git grep`), so a copied or zipped tree with no
# commits finds nothing and aborts mid-run. Copying the repo to run it privately is supported; you
# just have to commit once first. Fail fast with that instruction instead of a cryptic mid-run error.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "fork-init: not a git repository. Copying the repo is fine — initialise and commit first:" >&2
  echo "  git init && git add -A && git commit -m 'import platform'" >&2
  exit 1
fi
cd "$(git rev-parse --show-toplevel)"
if [ "$(git ls-files | wc -l | tr -d ' ')" = 0 ]; then
  echo "fork-init: no tracked files — 'git grep' only sees tracked content, so nothing would be rewritten." >&2
  echo "Commit your tree first, then re-run 'make fork-init':" >&2
  echo "  git add -A && git commit -m 'import platform'" >&2
  exit 1
fi

ENV="${ENV:-ai-dev}"
CFG="environments/${ENV}/config.yaml"
[ -f "$CFG" ] || { echo "fork-init: missing $CFG" >&2; exit 1; }

# Minimal YAML field reads (no yq dependency); values are plain scalars.
field() { awk -v k="$1" '$0 ~ "(^| )"k":" { sub(".*"k":[ \t]*",""); gsub(/[ \t"]/,""); print; exit }' "$2"; }

new_repo="$(field repoURL "$CFG")"
new_proj="$(field projectID "$CFG")"
new_domain="$(field domain "$CFG")"

# Old values from canonical manifests (NOT config.yaml — that already holds the new value).
old_repo="$(field repoURL clusters/${ENV}/appsets/platform.yaml)"
old_proj="$(field projectID platform/external-secrets/config/clustersecretstore.yaml)"

# Pre-flight consistency guard. fork-init discovers each "old" value from ONE canonical anchor and then
# literal-replaces it everywhere. If the value was hand-edited in some manifests but not the anchor before
# forking, those lagging files keep the template value while the anchor moves on, so the fix is computed
# as old==new and silently skipped — the wrong value survives, undetected. So at the moment a real
# replacement is due, assert the OTHER anchors shipping the same literal still hold the discovered old
# value. This checks the pre-fork "from" state ONLY and runs solely when old != new (a replace is
# pending); an already-forked repo with deliberately divergent per-component domains is never flagged.
guard_consistent() { # label old [anchor-file...]
  local label="$1" old="$2" f; shift 2
  local bad=()
  for f in "$@"; do
    [ -f "$f" ] || continue
    git grep -q -F "$old" -- "$f" || bad+=("$f")
  done
  [ "${#bad[@]}" -eq 0 ] && return 0
  {
    echo "fork-init: ABORT — inconsistent pre-fork template for $label."
    echo "  Anchor still holds the template value '$old', but these tracked files no longer contain it:"
    printf '    %s\n' "${bad[@]}"
    echo "  Finish the edit so every manifest holds one value, or 'git checkout' the listed files, then re-run 'make fork-init'."
  } >&2
  exit 1
}

replace() { # label old new [consistency-anchor-file...]
  local label="$1" old="$2" new="$3" files; shift 3
  [ -n "$old" ] || { echo "  ! $label: could not read current value" >&2; return; }
  [ -n "$new" ] || { echo "  ! $label: config.yaml value is empty" >&2; return; }
  [ "$old" != "$new" ] || { echo "  = $label unchanged ($old)"; return; }
  guard_consistent "$label" "$old" "$@"
  files="$(git grep -l -F "$old" || true)"
  [ -n "$files" ] || { echo "  = $label: no occurrences of $old"; return; }
  while IFS= read -r f; do
    old="$old" new="$new" perl -pi -e 'BEGIN{$o=$ENV{old};$n=$ENV{new}} s/\Q$o\E/$n/g' "$f"
  done <<< "$files"
  echo "  ~ $label: $old -> $new  ($(printf '%s\n' "$files" | wc -l | tr -d ' ') files)"
}

# repoBranch: the git branch every Argo source reconciles from. Unlike repoURL/projectID
# (distinctive strings safe for a literal global replace), the branch tokens `main`/`HEAD` are
# non-distinctive — `main` is a substring of `domain`. So this rewrites ONLY anchored git-source
# branch lines: `targetRevision:` on Application sources (catalog) and `targetRevision:`/`revision:`
# on the layer ApplicationSets — never a chart-version `targetRevision:` (numeric) or a bare `main`
# inside another word. HEAD is always normalized to the configured branch: a feature-branch fork must
# not track the repo's default branch.
replace_branch() { # old new
  local old="$1" new="$2" files f n=0
  [ -n "$new" ] || { echo "  ! repoBranch: config.yaml value is empty" >&2; return; }
  files="$(git grep -lE "^[[:space:]]*(targetRevision|revision):[[:space:]]+(HEAD|${old})[[:space:]]*\$" -- clusters platform serving routing workloads || true)"
  [ -n "$files" ] || { echo "  = repoBranch: no git-source branch refs found"; return; }
  while IFS= read -r f; do
    old="$old" new="$new" perl -pi -e 'BEGIN{$o=$ENV{old};$n=$ENV{new}} s/^([ \t]*(?:targetRevision|revision):[ \t]+)(?:HEAD|\Q$o\E)[ \t]*$/$1$n/' "$f"
    n=$((n+1))
  done <<< "$files"
  echo "  ~ repoBranch: {HEAD,$old} -> $new  ($n files)"
}

echo "fork-init ($ENV):"
replace repoURL   "$old_repo" "$new_repo" clusters/${ENV}/appsets/serving.yaml Makefile
replace projectID "$old_proj" "$new_proj" platform/external-secrets/values.yaml

# domain (ADR-0026): hostnames + ACME emails ship as the real literal so a clean checkout
# works locally; fork-init rewrites them in place, exactly like repoURL/projectID above. Old value is
# discovered from the ACME issuer email (admin@<domain>); new value comes from config.yaml. Empty
# domain in config = skip (edge stays dormant, Tier 0).
old_domain="$(awk -F'admin@' '/email: admin@/{gsub(/[ \t"]/,"",$2);print $2;exit}' routing/edge/cluster-issuer.yaml)"
if [ -n "$new_domain" ]; then
  replace domain "$old_domain" "$new_domain" bootstrap/argo-cd/values.yaml platform/dex/values.yaml
else
  echo "  = domain: empty in config.yaml — edge stays dormant (Tier 0)"
fi

# repoBranch: new value from config.yaml (default main); old value discovered from the git-source
# targetRevisions (non-numeric, non-HEAD) so a rename from a prior custom branch is also caught.
new_branch="$(field repoBranch "$CFG")"; new_branch="${new_branch:-main}"
old_branch="$(git grep -hE '^[[:space:]]*targetRevision:[[:space:]]' -- clusters \
  | sed -E 's/.*targetRevision:[[:space:]]*//; s/[[:space:]].*$//' \
  | grep -vxE '[0-9].*|HEAD' | sort -u | head -1)"
old_branch="${old_branch:-main}"
replace_branch "$old_branch" "$new_branch"

# Dex static-user password (ADR-0026): the admin bcrypt hash is NOT committed. `make seed-secrets`
# mints retrievable `dex-admin-password` plus `dex-admin-hash` in the backend; ESO delivers only the
# hash to Dex via env (staticPasswords[].hashFromEnv). Nothing to fill here.
echo "fork-init: config propagated across tracked files."
echo "Run 'make resolve-groups' to regenerate the *.generated.yaml from config; 'make fork-init' runs it next."
