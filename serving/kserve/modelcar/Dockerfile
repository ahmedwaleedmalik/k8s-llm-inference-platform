# OCI modelcar: weights-in-image (KServe modelcar, ADR-0016). busybox is the smallest base that
# still gives a shell + coreutils for the modelcar sidecar's `ln -sf` symlink step. Weights land at
# /models; KServe symlinks /mnt/models -> /models at serve time (no copy). Build via
# scripts/build-modelcar.sh (or cloudbuild.yaml for no-local-docker authors), which stages the HF
# snapshot into ./data/ first. Pin a digest after build — never serve :latest.
FROM busybox:1.38.0@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e
RUN mkdir -p /models
COPY data/ /models/
# Run as a non-root uid (DS-0002). The image only holds read-only weights at /models; KServe
# overrides the runtime securityContext for the modelcar sidecar, this is the build-time default.
USER 65532
