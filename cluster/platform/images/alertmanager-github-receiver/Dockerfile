# Upstream publishes measurementlab/alertmanager-github-receiver for amd64
# only. This builds the same source for the platform Docker asks for. Go
# cross-compiles, so the build stage runs on the build host's own platform.
FROM --platform=$BUILDPLATFORM golang:1.27@sha256:e432b43af23a9328d56a7c499be0476810aa344acbcf65fc7c455d4ff5a40602 AS build
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

FROM gcr.io/distroless/static:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
COPY --from=build /github_receiver /
ENTRYPOINT ["/github_receiver"]
