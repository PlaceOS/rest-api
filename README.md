# PlaceOS REST API

[![Build](https://github.com/PlaceOS/rest-api/actions/workflows/build.yml/badge.svg)](https://github.com/PlaceOS/rest-api/actions/workflows/build.yml)
[![CI](https://github.com/PlaceOS/rest-api/actions/workflows/ci.yml/badge.svg)](https://github.com/PlaceOS/rest-api/actions/workflows/ci.yml)

## Testing

Given you have the following dependencies...

- [docker](https://www.docker.com/)
- [docker-compose](https://github.com/docker/compose)

It is simple to develop the service with docker.

### With Docker

- Run specs, tearing down the `docker-compose` environment upon completion.

```shell-session
$ ./test
```

- Run specs on changes to Crystal files within the `src` and `spec` folders.

```shell-session
$ ./test --watch
```

### Without Docker

- To run tests

```shell-session
$ crystal spec
```

**NOTE:** The following dependencies are required...

- Elasticsearch `~> v7.6`
- RethinkDB `~> v2.4`
- Etcd `~> v3.3`
- Redis `~> v5`

## Compiling

```shell-session
$ shards build
```

### Deploying

Once compiled you are left with a binary: `bin/rest-api`.

- For help

```shell-session
$ ./bin/rest-api --help
```

- Viewing routes

```shell-session
$ ./bin/rest-api --routes
```

- Run on a different port or host

```shell-session
$ ./bin/rest-api -b 0.0.0.0 -p 80
```
