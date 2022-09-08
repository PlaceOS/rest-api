ARG CRYSTAL_VERSION=1.5.0
FROM alpine:3.16 as build
WORKDIR /app

# Set the commit via a build arg
ARG PLACE_COMMIT="DEV"
# Set the platform version via a build arg
ARG PLACE_VERSION="DEV"

# Create a non-privileged user, defaults are appuser:10001
ARG IMAGE_UID="10001"
ENV UID=$IMAGE_UID
ENV USER=appuser

# See https://stackoverflow.com/a/55757473/12429735
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

# Add trusted CAs for communicating with external services
RUN apk add \
  --update \
  --no-cache \
    ca-certificates \
    yaml-dev \
    yaml-static \
    libxml2-dev \
    openssl-dev \
    openssl-libs-static \
    zlib-dev \
    zlib-static \
    tzdata

RUN update-ca-certificates

# Add crystal lang
# can look up packages here: https://pkgs.alpinelinux.org/packages?name=crystal
RUN apk add \
  --update \
  --no-cache \
  --repository=http://dl-cdn.alpinelinux.org/alpine/edge/main \
  --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community \
    crystal \
    shards

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.override.yml shard.override.yml
COPY shard.lock shard.lock

RUN shards install --production --ignore-crystal-version --skip-postinstall --skip-executables

# Add src
COPY ./src /app/src

# Build application
RUN UNAME_AT_COMPILE_TIME=true \
    PLACE_COMMIT=$PLACE_COMMIT \
    PLACE_VERSION=$PLACE_VERSION \
    shards build --production --release --error-trace

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Extract binary dependencies
RUN for binary in "/bin/ping" "/bin/ping6"; do \
        ldd "$binary" | \
        tr -s '[:blank:]' '\n' | \
        grep '^/' | \
        xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'; \
      done

# Build a minimal docker image
FROM scratch
WORKDIR /
ENV PATH=$PATH:/

# Copy the user information over
COPY --from=build etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group

# These are required for communicating with external services
COPY --from=build /etc/hosts /etc/hosts

# These provide certificate chain validation where communicating with external services over TLS
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# This is required for Timezone support
COPY --from=build /usr/share/zoneinfo/ /usr/share/zoneinfo/

# this is required to ping things
COPY --from=build /bin/ping /ping
COPY --from=build /bin/ping6 /ping6

# Copy the app into place
COPY --from=build /app/deps /
COPY --from=build /app/bin /

# Use an unprivileged user.
USER appuser:appuser

# Run the app binding on port 3000
EXPOSE 3000
ENTRYPOINT ["/rest-api"]
HEALTHCHECK CMD ["/rest-api", "-c", "http://127.0.0.1:3000/api/engine/v2/"]
CMD ["/rest-api", "-b", "0.0.0.0", "-p", "3000"]
