#!/usr/bin/env bash
# Golden test — every workload image is a public, digest-pinned reference: a fork can pull it
# without private credentials, and the tag cannot drift under it. Scans the container images and
# OCI model artifacts under serving/ experience/ benchmarks/ workloads/ routing/.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

python3 - <<'PY'
import re, subprocess, sys

# docker.n8n.io is n8n's official public registry (credential-free pulls), like the others here.
ALLOWED_HOSTS = {"docker.io", "ghcr.io", "quay.io", "registry.k8s.io", "docker.n8n.io"}
PRIVATE = re.compile(r"(\.pkg\.dev/|\.dkr\.ecr\.|azurecr\.io/|gcr\.io/[^/]*\d)")

out = subprocess.run(
    ["git", "grep", "-hE", "image: |oci://", "--",
     "serving", "experience", "benchmarks", "workloads", "routing"],
    capture_output=True, text=True).stdout

refs = set()
for line in out.splitlines():
    line = re.sub(r"#.*", "", line)
    m = re.search(r"image:\s*(\S+)", line)
    if m:
        refs.add(m.group(1).strip("\"'"))
    for o in re.findall(r"oci://\S+", line):
        refs.add(o.strip("\"'"))

fail = 0
for ref in sorted(refs):
    img = ref[len("oci://"):] if ref.startswith("oci://") else ref
    if "/" in img:
        first = img.split("/", 1)[0]
        host = first if ("." in first or ":" in first) else "docker.io"
    else:
        host = "docker.io"  # single-segment ref = Docker Hub official image (node, busybox)

    if PRIVATE.search(img):
        print(f"FAIL private/project registry: {ref}"); fail = 1; continue
    if host not in ALLOWED_HOSTS:
        print(f"FAIL non-public registry host '{host}': {ref}"); fail = 1; continue
    if "@sha256:" not in img:
        print(f"FAIL not digest-pinned: {ref}"); fail = 1; continue
    print(f"OK   {ref}")

if not refs:
    print("FAIL no image references found (scan globs wrong?)"); fail = 1

sys.exit(fail)
PY
