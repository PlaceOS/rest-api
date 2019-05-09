# Crystal Engine REST API

[![Build Status](https://travis-ci.org/aca-labs/crystal-engine-rest-api.svg?branch=master)](https://travis-ci.org/aca-labs/crystal-engine-rest-api)


## Testing

`crystal spec --no-debug`

* the `--no-debug` flag is a bandaid for an as of yet undiagnosed LLVM issue.
* to run in development mode `crystal ./src/app.cr`

## Compiling

`crystal build ./src/app.cr`

### Deploying

Once compiled you are left with a binary `./app`

* for help `./app --help`
* viewing routes `./app --routes`
* run on a different port or host `./app -b 0.0.0.0 -p 80`
