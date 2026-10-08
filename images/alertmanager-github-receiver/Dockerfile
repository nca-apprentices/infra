# Upstream publishes measurementlab/alertmanager-github-receiver for amd64
# only. This builds the same source for the platform Docker asks for. Go
# cross-compiles, so the build stage runs on the build host's own platform.
FROM --platform=$BUILDPLATFORM golang:1.27 AS build
ARG VERSION TARGETOS TARGETARCH
RUN git clone --depth 1 --branch "$VERSION" \
    https://github.com/m-lab/alertmanager-github-receiver /src
WORKDIR /src
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build \
    -ldflags "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(git log -1 --format=%h) -w -s" \
    -o /github_receiver ./cmd/github_receiver

FROM gcr.io/distroless/static:nonroot
COPY --from=build /github_receiver /
ENTRYPOINT ["/github_receiver"]
