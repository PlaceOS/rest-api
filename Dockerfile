ARG CRYSTAL_VERSION=latest

FROM placeos/crystal:$CRYSTAL_VERSION AS build
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

# Install package updates since image release
RUN apk update && apk --no-cache --quiet upgrade

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
    shards build --production --error-trace --static

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Extract binary dependencies
RUN for binary in "/bin/ping" "/bin/ping6" "/usr/bin/git" /app/bin/* /usr/libexec/git-core/*; do \
    ldd "$binary" | \
    tr -s '[:blank:]' '\n' | \
    grep '^/' | \
    xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;' || true; \
    done

RUN git config --system http.sslCAInfo /etc/ssl/certs/ca-certificates.crt

# Create tmp directory with proper permissions
RUN rm -rf /tmp && mkdir -p /tmp && chmod 1777 /tmp

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
COPY --from=build /etc/gitconfig /etc/gitconfig
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt

# This is required for Timezone support
COPY --from=build /usr/share/zoneinfo/ /usr/share/zoneinfo/

# Copy tmp directory
COPY --from=build /tmp /tmp

# chmod for setting permissions on /tmp
COPY --from=build /bin /bin
COPY --from=build /lib/ld-musl-* /lib/
RUN chmod -R a+rwX /tmp
# hadolint ignore=SC2114,DL3059
RUN rm -rf /bin /lib

# this is required to ping things
COPY --from=build /bin/ping /ping
COPY --from=build /bin/ping6 /ping6

# git for querying remote repositories
COPY --from=build /usr/bin/git /git
COPY --from=build /usr/share/git-core/ /usr/share/git-core/
COPY --from=build /usr/libexec/git-core/ /usr/libexec/git-core/

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
