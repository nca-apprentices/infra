# Upstream publishes measurementlab/alertmanager-github-receiver for amd64
# only. This builds the same source for the platform Docker asks for. Go
# cross-compiles, so the build stage runs on the build host's own platform.
FROM --platform=$BUILDPLATFORM golang:1.27 AS build
# The commit the v0.11 tag points at, so a moved tag can't change the build.
ARG COMMIT=3f7b053f35fa8f45a7b7a8152fd0635bf4af4091
ARG TARGETOS TARGETARCH
WORKDIR /src
RUN git init --quiet \
    && git fetch --quiet --depth 1 \
    https://github.com/m-lab/alertmanager-github-receiver "$COMMIT" \
    && git checkout --quiet FETCH_HEAD
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build \
    -ldflags "-X github.com/m-lab/go/prometheusx.GitShortCommit=$(git log -1 --format=%h) -w -s" \
    -o /github_receiver ./cmd/github_receiver

FROM gcr.io/distroless/static:nonroot
COPY --from=build /github_receiver /
ENTRYPOINT ["/github_receiver"]
