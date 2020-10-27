# PlaceOS REST API

[![Build Status](https://travis-ci.com/placeos/rest-api.svg?branch=master)](https://travis-ci.com/placeos/rest-api)

## Testing

### Without Docker

- `crystal spec` to run tests

**Dependencies**

- Elasticsearch `~> v7.2`
- RethinkDB `~> v2.3.6`
- Etcd `~> v3.3.13`
- Redis `~> v5`

### With Docker

- `$ ./test` (tear down the docker-compose environment)
- `$ ./test --watch` (only run tests on change)
- `$ docker-compose down` when you are done with development work for the day

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

## Inspecting minimal images

1. To view the env vars use `docker inspect rest-api` and find the `Env` section
2. For a better view of env vars `docker inspect -f '{{range $index, $value := .Config.Env}}{{println $value}}{{end}}' rest-api`
3. To signal the process use `docker kill -s USR1 rest-api` (debug mode)
4. To signal the process use `docker kill -s USR2 rest-api` (default mode)
