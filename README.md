# Crystal ACAEngine REST API

[![Build Status](https://travis-ci.org/aca-labs/crystal-engine-rest-api.svg?branch=master)](https://travis-ci.org/aca-labs/crystal-engine-rest-api)


## Testing

`crystal spec --no-debug` to run tests

* the `--no-debug` flag is a bandaid for an as of yet undiagnosed LLVM issue.

## Compiling

`crystal build --no-debug ./src/engine-api.cr`

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
