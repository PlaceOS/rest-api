# PlaceOS REST API

[![Build Dev Image](https://github.com/PlaceOS/rest-api/actions/workflows/build-dev-image.yml/badge.svg)](https://github.com/PlaceOS/rest-api/actions/workflows/build-dev-image.yml)
[![CI](https://github.com/PlaceOS/rest-api/actions/workflows/ci.yml/badge.svg)](https://github.com/PlaceOS/rest-api/actions/workflows/ci.yml)

## Testing

### With Docker

- `$ ./test` (tear down the docker-compose environment)
- `$ ./test --watch` (only run tests on changes to `src` and `spec` folders)
- `$ docker-compose down` when you are done!

### Without Docker

- `crystal spec` to run tests

**Dependencies**

- Elasticsearch `~> v7.2`
- RethinkDB `~> v2.4`
- Etcd `~> v3.3`
- Redis `~> v5`

**Dependencies**

- [docker](https://www.docker.com/)
- [docker-compose](https://github.com/docker/compose)
- [git](https://git-scm.com/)

## Compiling

`crystal build ./src/rest-api.cr`

### Deploying

Once compiled you are left with a binary `./rest-api`

- for help `./rest-api --help`
- viewing routes `./rest-api --routes`
- run on a different port or host `./rest-api -b 0.0.0.0 -p 80`
