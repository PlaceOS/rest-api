FROM crystallang/crystal:0.33.0-alpine

WORKDIR /app

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.lock shard.lock

RUN shards install --production

# Add src
COPY ./src /app/src

# Build application
ENV UNAME_AT_COMPILE_TIME=true
RUN crystal build --release --debug --error-trace /app/src/rest-api.cr

# Extract dependencies
RUN ldd /app/rest-api | tr -s '[:blank:]' '\n' | grep '^/' | \
    xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'

RUN ldd /bin/ping | tr -s '[:blank:]' '\n' | grep '^/' | \
    xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'

RUN ldd /bin/ping6 | tr -s '[:blank:]' '\n' | grep '^/' | \
    xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'

# Build a minimal docker image
FROM scratch
WORKDIR /
ENV PATH=$PATH:/
COPY --from=0 /app/deps /
COPY --from=0 /app/rest-api /rest-api

# this is required to ping things
COPY --from=0 /bin/ping /ping
COPY --from=0 /bin/ping6 /ping6

# These are required for communicating with external services
COPY --from=0 /etc/hosts /etc/hosts

# Run the app binding on port 3000
EXPOSE 3000
HEALTHCHECK CMD ["/rest-api", "-c", "http://127.0.0.1:3000/api/engine/v2/"]
CMD ["/rest-api", "-b", "0.0.0.0", "-p", "3000"]
