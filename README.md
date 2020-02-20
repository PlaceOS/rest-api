# Crystal ACAEngine REST API

[![Build Status](https://travis-ci.com/acaengine/rest-api.svg?branch=master)](https://travis-ci.com/acaengine/rest-api)

## Testing

`crystal spec` to run tests

## Compiling

`crystal build ./src/engine-api.cr`

## Dependencies

- Elasticsearch `~> v7.2`
- RethinkDB `~> v2.3.6`
- Etcd `~> v3.3.13`
- Redis `~> v5`

### Deploying

Once compiled you are left with a binary `./engine-api`

* for help `./engine-api --help`
* viewing routes `./engine-api --routes`
* run on a different port or host `./engine-api -b 0.0.0.0 -p 80`

## Inspecting minimal images

1. To view the env vars use `docker inspect api` and find the `Env` section
2. For a better view of env vars `docker inspect -f '{{range $index, $value := .Config.Env}}{{println $value}}{{end}}' api`
3. To signal the process use `docker kill -s USR1 api` (debug mode)
4. To signal the process use `docker kill -s USR2 api` (default mode)
