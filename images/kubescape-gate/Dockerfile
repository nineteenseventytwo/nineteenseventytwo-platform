# kubescape-gate - see README.md. A static Go binary on distroless: no shell, no package
# manager, nothing for the weekly scan to find except the binary and the CA
# bundle. Both stages pinned by digest, like every image here.
FROM golang:1.27.3-alpine@sha256:b8c9b82affbbb82a020bbcf998dad2ba9516944ac7e883524642a481a9505e9c AS build
WORKDIR /src
COPY . .
RUN go vet ./... && go test ./... \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/kubescape-gate .

FROM gcr.io/distroless/static-debian13:nonroot@sha256:18f4cc26c9ffa7f20a359298be7deadac5c607c8e03a02b8119f1a5fc2f82c99
COPY --from=build /out/kubescape-gate /kubescape-gate
# distroless's nonroot user. Numeric, so the CronJob's runAsNonRoot can
# verify it without reading /etc/passwd.
USER 65532:65532
# Kubernetes ignores HEALTHCHECK; it runs as a Job, whose exit code is the
# check. Stated explicitly so the scanner reads it as a decision.
HEALTHCHECK NONE
ENTRYPOINT ["/kubescape-gate"]
