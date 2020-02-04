FROM crystallang/crystal:0.32.1

WORKDIR /app

# Add
# - ping (not in base xenial image the crystal image is based off)
# - curl
RUN apt-get update && \
    apt-get install --no-install-recommends -y iputils-ping curl && \
    rm -rf /var/lib/apt/lists/*

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.lock shard.lock

RUN shards install --production

# Add src
COPY ./src /app/src

# Build application
ENV UNAME_AT_COMPILE_TIME=true
RUN crystal build --error-trace /app/src/engine-api.cr

# Extract dependencies
RUN ldd /app/engine-api | tr -s '[:blank:]' '\n' | grep '^/' | \
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
COPY --from=0 /app/engine-api /engine-api

# this is required to ping things
COPY --from=0 /bin/ping /ping
COPY --from=0 /bin/ping6 /ping6

# These are required for communicating with external services
COPY --from=0 /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_dns.so.2
COPY --from=0 /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2

# Run the app binding on port 3000
EXPOSE 3000
HEALTHCHECK CMD curl -I localhost:3000/api/engine/v2/
CMD ["/engine-api", "-b", "0.0.0.0", "-p", "3000"]
