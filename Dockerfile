FROM crystallang/crystal:0.29.0

COPY . /src
WORKDIR /src

# Prerequisite for libscrypt install
RUN apt-get -qq update -dd
RUN apt-get -qq install -y curl

# Install dependencies
RUN shards install

# Manually remake libscrypt, PostInstall fails inexplicably
# RUN make -C ./lib/scrypt/ clean
# RUN make -C ./lib/scrypt/

# Build App
RUN shards build --production --no-debug

# Extract dependencies
RUN ldd bin/engine-api | tr -s '[:blank:]' '\n' | grep '^/' | xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'

# Build a minimal docker image
FROM busybox:glibc
COPY --from=0 /src/deps /
COPY --from=0 /src/bin/engine-api /engine-api

# Run the app binding on port 3000
EXPOSE 3000
HEALTHCHECK CMD wget --spider localhost:3000/
ENTRYPOINT ["/engine-api"]
CMD ["/engine-api", "-b", "0.0.0.0", "-p", "3000"]
