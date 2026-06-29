#!/usr/bin/env bash
# Golden test for the gpu_stack knob: each value must (a) render the right DCGM scrape target via
# scripts/resolve-gpu.sh and (b) toggle the gpu-operator group via scripts/resolve-groups.sh.
# norm() loads YAML (drops comments) so only semantic content is compared. Writes into temp dirs so the
# live platform/dcgm-metrics + clusters/*/groups.generated.yaml are never touched.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
norm() { python3 -c "import sys,yaml; print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1])),sort_keys=True))" "$1"; }
check() { # actual expected label
  if diff <(norm "$1") <(norm "$2") >/dev/null; then echo "OK   $3"; else
    echo "FAIL $3"; diff <(norm "$1") <(norm "$2") || true; fail=1; fi
}
fail=0
FX=tests/gpu-stack-selection/fixtures
EXP=tests/gpu-stack-selection/expected

# (a) DCGM scrape target rendered by resolve-gpu. default → gke-managed; operator/none → empty kustomization.
for v in gke-managed operator none default; do
  d="$(mktemp -d)"
  CFG="$FX/${v}.config.yaml" DIR="$d" ./scripts/resolve-gpu.sh >/dev/null
  check "$d/kustomization.yaml" "$EXP/${v}.kustomization.yaml" "resolve-gpu: $v kustomization"
  if [ -f "$EXP/${v}.podmonitor.yaml" ]; then
    check "$d/podmonitor.generated.yaml" "$EXP/${v}.podmonitor.yaml" "resolve-gpu: $v podmonitor"
  elif [ -f "$d/podmonitor.generated.yaml" ]; then
    echo "FAIL resolve-gpu: $v rendered a podmonitor but none expected"; fail=1
  else
    echo "OK   resolve-gpu: $v no podmonitor"
  fi
  rm -rf "$d"
done

# (b) gpu-operator group enabled ONLY when gpu_stack=operator.
for v in gke-managed operator none default; do
  CFG="$FX/${v}.config.yaml" OUT="/tmp/gpu-${v}.groups.yaml" ./scripts/resolve-groups.sh >/dev/null 2>&1
  want="false"; [ "$v" = operator ] && want="true"
  got="$(awk -F'"' '/name: gpu-operator,/{print $2}' "/tmp/gpu-${v}.groups.yaml")"
  if [ "$got" = "$want" ]; then echo "OK   group: gpu-operator enabled=$got for gpu_stack=$v"; else
    echo "FAIL group: gpu-operator enabled=$got (want $want) for gpu_stack=$v"; fail=1; fi
done

exit "$fail"
