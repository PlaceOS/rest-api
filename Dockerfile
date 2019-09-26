FROM crystallang/crystal:0.30.1

WORKDIR /app

# Add
# - curl (necessary for scrypt install)
# - ping (not in base xenial image the crystal image is based off)
RUN apt-get update && \
    apt-get install --no-install-recommends -y iputils-ping=3:20121221-5ubuntu2 && \
    rm -rf /var/lib/apt/lists/*

# Install shards for caching
COPY shard.yml shard.yml
RUN shards install --production

# Add src
COPY ./src /app/src

# Build application
RUN crystal build /app/src/engine-api.cr --release --no-debug

# Run the app binding on port 3000
EXPOSE 3000
HEALTHCHECK CMD wget --spider localhost:3000/
CMD ["/app/engine-api", "-b", "0.0.0.0", "-p", "3000"]
