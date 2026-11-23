# OCI modelcar: weights-in-image (KServe modelcar, ADR-0016). busybox is the smallest base that
# still gives a shell + coreutils for the modelcar sidecar's `ln -sf` symlink step. Weights land at
# /models; KServe symlinks /mnt/models -> /models at serve time (no copy). Build via
# scripts/build-modelcar.sh (or cloudbuild.yaml for no-local-docker authors), which stages the HF
# snapshot into ./data/ first. Pin a digest after build — never serve :latest.
FROM busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4
RUN mkdir -p /models
COPY data/ /models/
# Run as a non-root uid (DS-0002). The image only holds read-only weights at /models; KServe
# overrides the runtime securityContext for the modelcar sidecar, this is the build-time default.
USER 65532
