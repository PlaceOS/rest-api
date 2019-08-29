FROM crystallang/crystal:0.30.1

# Add curl (necessary for scrypt install)
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Install shards for caching
COPY shard.yml shard.yml
RUN shards install --production

# Add src
COPY . /app

# Manually remake libscrypt, PostInstall fails inexplicably
RUN make -C /app/lib/scrypt/ clean
RUN make -C /app/lib/scrypt/

# Build application
RUN crystal build app/src/engine-api.cr --release --no-debug

# Run the app binding on port 3000
EXPOSE 3000
HEALTHCHECK CMD wget --spider localhost:3000/
CMD ["/engine-api", "-b", "0.0.0.0", "-p", "3000"]
