#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(".")

llmisvc = yaml.safe_load((root / "clusters/ai-dev/catalog/kserve/kserve-llmisvc.yaml").read_text())
values = yaml.safe_load((root / "platform/kserve/llmisvc-values.yaml").read_text())
presets = yaml.safe_load((root / "clusters/ai-dev/catalog/kserve/kserve-llmisvc-presets.yaml").read_text())

errors = []

if values.get("kserve", {}).get("createSharedResources") is not False:
    errors.append("platform/kserve/llmisvc-values.yaml must set kserve.createSharedResources: false")

if "source" in llmisvc.get("spec", {}):
    errors.append("kserve-llmisvc must use spec.sources so it can load repo-owned Helm values")

sources = llmisvc.get("spec", {}).get("sources", [])
chart_source = next((s for s in sources if s.get("chart") == "kserve-llmisvc-resources"), None)
values_source = next((s for s in sources if s.get("ref") == "values"), None)

if not chart_source:
    errors.append("kserve-llmisvc chart source missing")
else:
    value_files = chart_source.get("helm", {}).get("valueFiles", [])
    if "$values/platform/kserve/llmisvc-values.yaml" not in value_files:
        errors.append("kserve-llmisvc chart must load $values/platform/kserve/llmisvc-values.yaml")

if not values_source:
    errors.append("kserve-llmisvc values source missing")

expected_pointers = {
    "/spec/router/route/http/spec/rules/6/backendRefs/0/group",
    "/spec/router/route/http/spec/rules/7/backendRefs/0/group",
    "/spec/router/route/http/spec/rules/7/matches/0/path",
}
actual_pointers = set()
for diff in presets.get("spec", {}).get("ignoreDifferences", []):
    if (
        diff.get("group") == "serving.kserve.io"
        and diff.get("kind") == "LLMInferenceServiceConfig"
        and diff.get("name") == "kserve-config-llm-router-route"
        and diff.get("namespace") == "kserve"
    ):
        actual_pointers.update(diff.get("jsonPointers", []))

missing = expected_pointers - actual_pointers
if missing:
    errors.append("kserve-llmisvc-presets missing ignoreDifferences pointers: " + ", ".join(sorted(missing)))

if errors:
    for error in errors:
        print(f"FAIL {error}")
    sys.exit(1)

print("OK   kserve app ownership")
PY
