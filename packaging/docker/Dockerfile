# The image published as ghcr.io/ecorreiax/ffmig. The release workflow
# builds it from the Linux binaries it has just built and tested, placed
# next to this file as ffmig-linux-amd64 and ffmig-linux-arm64.
#
#   docker run --rm -v "$PWD:/app" -e DATABASE_URL ghcr.io/ecorreiax/ffmig migrate
FROM debian:bookworm-slim

# libpq with TLS for managed databases, and the CA certificates that
# sslmode=verify-full checks the server against.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
COPY --chmod=755 ffmig-linux-${TARGETARCH} /usr/local/bin/ffmig

WORKDIR /app
ENTRYPOINT ["ffmig"]
