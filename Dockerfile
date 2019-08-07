FROM alpine:3.10

RUN apk update && \
    apk add crystal shards curl

COPY . /src
WORKDIR /src

# Install dependencies
RUN shards install

# Build App
RUN shards build --production --no-debug

# Extract dependencies
RUN ldd bin/engine-api | tr -s '[:blank:]' '\n' | grep '^/' | xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'

# Build a minimal docker image
FROM alpine:3.10
COPY --from=0 /src/deps /
COPY --from=0 /src/bin/engine-api /engine-api

# Run the app binding on port 3000
EXPOSE 3000
HEALTHCHECK CMD wget --spider localhost:3000/
CMD ["/engine-api", "-b", "0.0.0.0", "-p", "3000"]
