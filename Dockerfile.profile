FROM crystallang/crystal:1.0.0-alpine
WORKDIR /app

# Set the commit via a build arg
ARG PLACE_COMMIT="DEV"
# Set the platform version via a build arg
ARG PLACE_VERSION="DEV"

# Create a non-privileged user, defaults are appuser:10001
ARG IMAGE_UID="10001"
ENV UID=$IMAGE_UID
ENV USER=appuser

# See https://stackoverflow.com/a/55757473/12429735RUN
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

RUN apk update && \
    apk upgrade && \
    apk add --no-cache \
      ca-certificates \
      perf

RUN  update-ca-certificates

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.override.yml shard.override.yml
COPY shard.lock shard.lock

RUN shards install --production --ignore-crystal-version

# Add src
COPY ./src /app/src

# Build application
RUN UNAME_AT_COMPILE_TIME=true \
    PLACE_COMMIT=$PLACE_COMMIT \
    PLACE_VERSION=$PLACE_VERSION \
    crystal build --debug --release --error-trace /app/src/app.cr -o /app/rest-api

# Use an unprivileged user.
USER appuser:appuser

# Run the app binding on port 3000
EXPOSE 3000
HEALTHCHECK CMD ["/app/rest-api", "-c", "http://127.0.0.1:3000/api/engine/v2/"]
CMD ["perf", "record", "--call-graph", "dwarf", "/app/rest-api", "-b", "0.0.0.0", "-p", "3000"]
