# OCI modelcar: weights-in-image (KServe modelcar, ADR-0016). busybox is the smallest base that
# still gives a shell + coreutils for the modelcar sidecar's `ln -sf` symlink step. Weights land at
# /models; KServe symlinks /mnt/models -> /models at serve time (no copy). Build via
# scripts/build-modelcar.sh (or cloudbuild.yaml for no-local-docker authors), which stages the HF
# snapshot into ./data/ first. Pin a digest after build — never serve :latest.
FROM busybox:1.38.0@sha256:fd8d9aa63ba2f0982b5304e1ee8d3b90a210bc1ffb5314d980eb6962f1a9715d
RUN mkdir -p /models
COPY data/ /models/
# Run as a non-root uid (DS-0002). The image only holds read-only weights at /models; KServe
# overrides the runtime securityContext for the modelcar sidecar, this is the build-time default.
USER 65532
