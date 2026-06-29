#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ENV="${ENV:-ai-dev}"
PROFILE="${PROFILE:-platform}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-10}"

case "$PROFILE" in
  platform) layers="platform" ;;
  serving) layers="platform serving" ;;
  llm-gateway) layers="platform serving routing llm-gateway" ;;
  full) layers="platform serving routing llm-gateway experience demos" ;;
  *) echo "unknown PROFILE=$PROFILE (use platform|serving|llm-gateway|full)" >&2; exit 1 ;;
esac

manual_apps=" raw-vllm coder-chat coder-fim coder-agent dex oauth2-proxy external-dns edge key-portal kserve-demo inference-demo llm-d n8n "

app_name() {
  awk '$1=="name:" {print $2; exit}' "$1"
}

groups_file="clusters/${ENV}/groups.generated.yaml"
apps=""
for layer in $layers; do
  group_paths="$(python3 -c "import yaml; print('\n'.join(g['catalogPath'] for g in yaml.safe_load(open('$groups_file')) if g['layer']=='$layer' and g['enabled']=='true'))")"
  for gpath in $group_paths; do
    for f in "$gpath"/*.yaml; do
      [ -e "$f" ] || continue
      app="$(app_name "$f")"
      case "$manual_apps" in
        *" $app "*) continue ;;
      esac
      apps="$apps $app"
    done
  done
done

deadline=$((SECONDS + TIMEOUT_SECONDS))
for app in $apps; do
  echo "==> wait $app"
  while true; do
    json="$(kubectl -n argocd get application "$app" -o json 2>/dev/null || true)"
    if [ -n "$json" ]; then
      sync="$(printf '%s' "$json" | jq -r '.status.sync.status // "Unknown"')"
      health="$(printf '%s' "$json" | jq -r '.status.health.status // "Unknown"')"
      if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
        echo "OK   $app Synced Healthy"
        break
      fi
      echo "     $app sync=$sync health=$health"
    else
      echo "     $app missing"
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "FAIL timed out waiting for $app" >&2
      exit 1
    fi
    sleep "$INTERVAL_SECONDS"
  done
done
