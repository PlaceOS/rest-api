## Unreleased

### Feat

- PPT-1329: Removed git related methods from rest-api ([#386](https://github.com/PlaceOS/rest-api/pull/386))
- PPT-1323 Added endpoint for module error retrieval ([#382](https://github.com/PlaceOS/rest-api/pull/382))
- migrate to using redis service manager ([#380](https://github.com/PlaceOS/rest-api/pull/380))
- **short_url**: add api routes ([#379](https://github.com/PlaceOS/rest-api/pull/379)) [PPT-1237]
- integrate build service ([#370](https://github.com/PlaceOS/rest-api/pull/370))
- **chat_gpt/plugin**: interaction API ([#378](https://github.com/PlaceOS/rest-api/pull/378))
- add signage API [PPT-1040] ([#377](https://github.com/PlaceOS/rest-api/pull/377))
- **uploads**: add temp link env vars
- PPT-1085 Add OpenAI Tool Call support ([#369](https://github.com/PlaceOS/rest-api/pull/369))
- allow public.read to work
- **chat_gpt**: make the default API model configurable
- PPT-524 Integrate the build service into core ([#367](https://github.com/PlaceOS/rest-api/pull/367))
- **chat_gpt**: compress chats once tasks are completed ([#366](https://github.com/PlaceOS/rest-api/pull/366))
- **chat_gpt**: provides the current date and time with each request
- **chat_gpt/chat_manager**: migrate to using status where possible
- **chat_gpt**: update prompt with users details
- PPT-568 Added Controller for ChatBot ([#364](https://github.com/PlaceOS/rest-api/pull/364))
- **users**: enable user token access with appropriate scope
- PPT-864 fix and capture online and last seen activity ([#361](https://github.com/PlaceOS/rest-api/pull/361))
- **uploads**: improve upload validation ([#360](https://github.com/PlaceOS/rest-api/pull/360))
- **uploads**: improve documentation
- PPT-767 File Upload controller ([#357](https://github.com/PlaceOS/rest-api/pull/357))
- add concierge permissions PPT-746 ([#355](https://github.com/PlaceOS/rest-api/pull/355))
- **assets**: add permissions system PPT-743 ([#354](https://github.com/PlaceOS/rest-api/pull/354))
- **users**: PPT-53 Add User metadata search ([#353](https://github.com/PlaceOS/rest-api/pull/353))
- **notifications**: publish on subscription id ([#352](https://github.com/PlaceOS/rest-api/pull/352))
- **asset_types**: filter counts based on zone_id ([#349](https://github.com/PlaceOS/rest-api/pull/349))
- **assets**: add additional query options (PPT-669) ([#347](https://github.com/PlaceOS/rest-api/pull/347))
- **shard.lock**: bump opentelemetry-instrumentation.cr
- **assets**: add zone_id filtering
- PPT-520 ([#346](https://github.com/PlaceOS/rest-api/pull/346))
- **asset_manager**: change ids to strings ([#345](https://github.com/PlaceOS/rest-api/pull/345))
- **asset_manager**: [PPT-335] new asset manager endpoints ([#343](https://github.com/PlaceOS/rest-api/pull/343))
- **Dockerfile**: improve compile times and backtraces
- **webrtc**: add a call signaling controller ([#332](https://github.com/PlaceOS/rest-api/pull/332))
- **repositories**: add branch support ([#333](https://github.com/PlaceOS/rest-api/pull/333))
- **webhook**: add support for binary payloads ([#330](https://github.com/PlaceOS/rest-api/pull/330))
- **shards**: update shards ([#326](https://github.com/PlaceOS/rest-api/pull/326))
- **repositories**: add additional helper methods ([#317](https://github.com/PlaceOS/rest-api/pull/317))
- **systems**: additional options for querying using email ([#315](https://github.com/PlaceOS/rest-api/pull/315))
- **utilities/current-user**: log when an API key is being used ([#312](https://github.com/PlaceOS/rest-api/pull/312))
- **Dockerfile**: add support for ARM64 builds ([#297](https://github.com/PlaceOS/rest-api/pull/297))
- **users**: allow any authenticated user to list users ([#296](https://github.com/PlaceOS/rest-api/pull/296))
- **webhook**: add additional routes ([#293](https://github.com/PlaceOS/rest-api/pull/293))
- **application**: improve query result accuracy ([#290](https://github.com/PlaceOS/rest-api/pull/290))
- **users**: optionally include user metadata ([#288](https://github.com/PlaceOS/rest-api/pull/288))
- add metadata change signaling ([#286](https://github.com/PlaceOS/rest-api/pull/286))
- **users**: add route for deleting resource tokens ([#283](https://github.com/PlaceOS/rest-api/pull/283))

### Fix

- **specs**: clean and fix specs ([#384](https://github.com/PlaceOS/rest-api/pull/384))
- **repositories**: list the files on the correct branch ([#383](https://github.com/PlaceOS/rest-api/pull/383))
- **logging**: PPT-1368 - logging to use placeos-log-backend ([#381](https://github.com/PlaceOS/rest-api/pull/381))
- **repositories**: obtaining driver list
- **short_url**: svg rendering
- **playlist_media**: remove media from bucket
- **changefeeds**: ensure change listener for drivers table remain intact ([#375](https://github.com/PlaceOS/rest-api/pull/375))
- **user**: change WorktimePreference day to day_of_week ([#372](https://github.com/PlaceOS/rest-api/pull/372))
- **chatgpt**: provide day of the week details
- **root**: pg healthcheck with aurora db
- **uploads**: remove . from ext check
- allow start and stop of modules
- **resource**: replaced change feed iterator with async closure
- **eventbus**: handle read replica race conditions
- **eventbus**: handle read replica race conditions
- **asset_types**: zone filtering for counts ([#350](https://github.com/PlaceOS/rest-api/pull/350))
- **assets**: sort by id
- **assets**: authenticated users can view
- domain check skipped for x-api-keys ([#342](https://github.com/PlaceOS/rest-api/pull/342))
- **modules**: [PPT-32] search query ([#341](https://github.com/PlaceOS/rest-api/pull/341))
- **webrtc/clustered_sessions**: initializer spelling
- **webrtc**: exit signal not firing
- **webrtc**: make index route public ([#340](https://github.com/PlaceOS/rest-api/pull/340))
- edge exec lookup ([#329](https://github.com/PlaceOS/rest-api/pull/329))
- **repositories**: driver details when not using master branch ([#327](https://github.com/PlaceOS/rest-api/pull/327))
- **webhook**: resolve 404 on friendly webhook URI ([#325](https://github.com/PlaceOS/rest-api/pull/325))
- **edge/connection**: refactor how connections are handled ([#324](https://github.com/PlaceOS/rest-api/pull/324))
- **shard.lock**: bump core-client to fix cluster listing ([#323](https://github.com/PlaceOS/rest-api/pull/323))
- **webhook**: obtain body data before parsing params ([#320](https://github.com/PlaceOS/rest-api/pull/320))
- **repositories**: use frontend-loader to grab commits
- **Dockerfile**: add git to the image for querying remotes ([#318](https://github.com/PlaceOS/rest-api/pull/318))
- **utilities/scopes**: add `public` scope to scope list API ([#311](https://github.com/PlaceOS/rest-api/pull/311))
- **domains**: before action must set instance variable ([#310](https://github.com/PlaceOS/rest-api/pull/310))
- **Dockerfile**: include application dependencies in build
- **Dockerfile**: don't use edge libraries ([#298](https://github.com/PlaceOS/rest-api/pull/298))
- **websocket**: close write_channel on cleanup ([#291](https://github.com/PlaceOS/rest-api/pull/291))
- **metadata**: users can create their own metadata ([#287](https://github.com/PlaceOS/rest-api/pull/287))

### Refactor

- migrate to postgres ([#328](https://github.com/PlaceOS/rest-api/pull/328))

### Perf

- **metadata**: remove metadata querying ([#289](https://github.com/PlaceOS/rest-api/pull/289))

## v1.48.0 (2022-06-01)

### Feat

- **users**: add route for reviving a deleted user ([#280](https://github.com/PlaceOS/rest-api/pull/280))

## v1.47.1 (2022-05-17)

### Fix

- **repositories**: inconsistent pull responses ([#277](https://github.com/PlaceOS/rest-api/pull/277))

## v1.47.0 (2022-05-16)

### Feat

- **repositories**: new method for repository pull feedback ([#275](https://github.com/PlaceOS/rest-api/pull/275))

## v1.46.0 (2022-05-10)

### Feat

- **users**: resource token to default to first oauth app ([#273](https://github.com/PlaceOS/rest-api/pull/273))

## v1.45.0 (2022-05-06)

### Feat

- **controller/metadata**: add pagination for `query` route ([#271](https://github.com/PlaceOS/rest-api/pull/271))

## v1.44.4 (2022-05-06)

### Fix

- **controller/edges**: include `x_api_token` in Edge creation response ([#270](https://github.com/PlaceOS/rest-api/pull/270))

## v1.44.3 (2022-05-04)

### Fix

- **controller/edges**: default to logged in user ID

## v1.44.2 (2022-05-03)

### Fix

- **logging**: remove extra call to configure OpenTelemetry

## v1.44.1 (2022-05-03)

### Fix

- update `placeos-log-backend`

## v1.44.0 (2022-05-03)

### Feat

- **metadata**: PATCH to patch `details`, PUT to replace ([#269](https://github.com/PlaceOS/rest-api/pull/269))

## v1.43.2 (2022-04-30)

### Fix

- update `placeos-compiler`

## v1.43.1 (2022-04-28)

### Fix

- **telemetry**: seperate telemetry file

## v1.43.0 (2022-04-27)

### Feat

- **logging**: configure OpenTelemetry

## v1.42.0 (2022-04-26)

### Feat

- **logging**: add configuration by LOG_LEVEL env var

## v1.41.0 (2022-04-14)

### Feat

- **controllers/users**: ensure user_id continuity ([#265](https://github.com/PlaceOS/rest-api/pull/265))

## v1.40.0 (2022-04-14)

### Feat

- **metadata**: add `include_parent` to index

## v1.39.0 (2022-04-08)

### Feat

- **controller/metadata**: add an index method ([#264](https://github.com/PlaceOS/rest-api/pull/264))

## v1.38.0 (2022-04-06)

### Feat

- **repositories**: add releases endpoint ([#262](https://github.com/PlaceOS/rest-api/pull/262))

## v1.37.0 (2022-03-28)

### Feat

- add driver response codes to public API ([#261](https://github.com/PlaceOS/rest-api/pull/261))

## v1.36.0 (2022-03-28)

### Feat

- **user**: query by single email ([#260](https://github.com/PlaceOS/rest-api/pull/260))

## v1.35.1 (2022-03-23)

### Refactor

- **controllers**: remove `find_<model>` from `current_<model>` ([#259](https://github.com/PlaceOS/rest-api/pull/259))

## v1.35.0 (2022-03-23)

### Feat

- **metadata#history**: add `/metadata/:parent_id/history` ([#258](https://github.com/PlaceOS/rest-api/pull/258))

## v1.34.0 (2022-03-17)

### Feat

- set modifier for metadata and settings ([#256](https://github.com/PlaceOS/rest-api/pull/256))

## v1.33.4 (2022-03-03)

### Fix

- **controllers/modules**: extract status from exec response ([#242](https://github.com/PlaceOS/rest-api/pull/242))

## v1.33.3 (2022-03-02)

### Fix

- **systems execute**: fix response using driver status codes ([#240](https://github.com/PlaceOS/rest-api/pull/240))

## v1.33.2 (2022-03-02)

### Refactor

- **api**: `put_redirect` to prevent manual  update redirect ([#239](https://github.com/PlaceOS/rest-api/pull/239))

## v1.33.1 (2022-03-01)

### Fix

- **flux**: add support for influx query authentication tokens

## v1.33.0 (2022-03-01)

### Feat

- influx query proxy route on `/api/v2/query` ([#238](https://github.com/PlaceOS/rest-api/pull/238))

## v1.32.0 (2022-02-24)

### Feat

- **logging**: change severity via `LOG_LEVEL` environment variable ([#237](https://github.com/PlaceOS/rest-api/pull/237))

## v1.31.1 (2022-02-24)

### Feat

- **root**: add additional logging to signal requests ([#234](https://github.com/PlaceOS/rest-api/pull/234))
- **controllers:root**: add `/platform` to render platform metadata ([#228](https://github.com/PlaceOS/rest-api/pull/228))
- **users controller**: add support for user model soft delete ([#224](https://github.com/PlaceOS/rest-api/pull/224))
- **assets**: add controller & spec ([#222](https://github.com/PlaceOS/rest-api/pull/222))
- add helper methods for authenticating MQTT websocket access ([#219](https://github.com/PlaceOS/rest-api/pull/219))
- **api**: forward `user_id` for module executes ([#217](https://github.com/PlaceOS/rest-api/pull/217))
- **cluster api**: timeout requests for process details ([#208](https://github.com/PlaceOS/rest-api/pull/208))
- **users**: look up with authority ([#206](https://github.com/PlaceOS/rest-api/pull/206))

### Fix

- **root**: expose `/platform` ([#236](https://github.com/PlaceOS/rest-api/pull/236))
- **settings**: return models in same order as previously ([#229](https://github.com/PlaceOS/rest-api/pull/229))
- swallow channel errors in single document changefeeds ([#227](https://github.com/PlaceOS/rest-api/pull/227))
- **authentications controller**: authority_id param is optional
- **mqtt controller**: deny flag is also a read flag ([#223](https://github.com/PlaceOS/rest-api/pull/223))
- root service mocks ([#215](https://github.com/PlaceOS/rest-api/pull/215))
- session debug failures ([#207](https://github.com/PlaceOS/rest-api/pull/207))
- update scopes path
- **root**: forward status from rubber-soul ([#202](https://github.com/PlaceOS/rest-api/pull/202))
- **session**: scrub invalid UTF-8 chars from driver responses ([#201](https://github.com/PlaceOS/rest-api/pull/201))

### Refactor

- **edge**: ApiKey for edge token ([#235](https://github.com/PlaceOS/rest-api/pull/235))
- param getters ([#210](https://github.com/PlaceOS/rest-api/pull/210))
- `rubber-soul` -> `search-ingest` ([#211](https://github.com/PlaceOS/rest-api/pull/211))
- **api**: unify boolean param handling ([#209](https://github.com/PlaceOS/rest-api/pull/209))
- websocket api ([#203](https://github.com/PlaceOS/rest-api/pull/203))
- **spec**: use module class_getter for auth header ([#205](https://github.com/PlaceOS/rest-api/pull/205))

## v1.30.2 (2021-10-14)

### Feat

- **utilities current user**: x-api-key needs param support ([#197](https://github.com/PlaceOS/rest-api/pull/197))

### Refactor

- session writes ([#200](https://github.com/PlaceOS/rest-api/pull/200))
- use new dispatch endpoint ([#196](https://github.com/PlaceOS/rest-api/pull/196))

## v1.30.1 (2021-10-08)

### Fix

- **session**: args is optional ([#195](https://github.com/PlaceOS/rest-api/pull/195))
- **responders**: callback skipped on model creation ([#193](https://github.com/PlaceOS/rest-api/pull/193))
- **api/modules**: remove parent index query
- **api:cluster**: improve error handling when requesting core status

### Refactor

- **user**: use new Email struct ([#194](https://github.com/PlaceOS/rest-api/pull/194))

## v1.30.0 (2021-09-16)

### Feat

- add Granular OAuth Scopes ([#169](https://github.com/PlaceOS/rest-api/pull/169))
- metadata endpoints on entites ([#167](https://github.com/PlaceOS/rest-api/pull/167))
- log context for failed version queries
- user lookup via secondary indices
- **api-keys**: provide a method for inspecting the keys JWT ([#155](https://github.com/PlaceOS/rest-api/pull/155))
- add api key CRUD methods ([#154](https://github.com/PlaceOS/rest-api/pull/154))
- **versions**: add source version to cluster

### Fix

- **shard.override.yml**: use correct rethinkdb override
- **api:repositories**: account for branches in commit listing ([#181](https://github.com/PlaceOS/rest-api/pull/181))
- **users**: user ids don't always start_with table_name ([#172](https://github.com/PlaceOS/rest-api/pull/172))
- **api/repositories**: pull on each pull request ([#148](https://github.com/PlaceOS/rest-api/pull/148))
- **session**: shrink caches, sync access

### Refactor

- **session**: better log contexts

### Perf

- **controller/systems**: use tally_by

## v1.29.0 (2021-07-06)

### Feat

- **root**: add promises for service versions
- add service versions route
- **root**: add `Version`
- add JSON schema CRUD routes
- **controllers/user:destroy**: render errors
- **controllers/repositories**: support branch switching

### Fix

- **controllers/metadata**: start json array
- **responders**: turn render_json into macro
- **metadata**: params typo
- **controllers/metadata**: ensure presence of `name` param
- **reponders**: correct method on JSON
- **controllers/users**: groups query info leak
- **controllers/users**: better rendering of User json
- **controller/root**: remove Nil types, add rest-api to versions
- **root**: correct URIs for core + dispatch
- change construct_versions to macros
- service routes
- **repositories**: client error for invalid reqs
- **logging**: set progname

### Refactor

- **controllers/metadta**: remove NamedTuple
- **responders**: pass a JSON::Builder instead of response IO
- try to get service version spec running

### Perf

- **controllers/metadata**: use IO to render iterator

## v1.27.0 (2021-04-29)

### Feat

- **log**: configure raven log backend and exception handler
- **logging**: register log level change signals

### Refactor

- **current_user**: touch-up

## v1.26.1 (2021-04-14)

### Feat

- **session**: catch errors in debug message handler
- **root**: add a healthcheck that ensures the presence of etcd/rethinkdb/redis
- **controller:drivers**: return compilation output if binary not found

### Fix

- **session**: parse `Log::Severity` from value in debug frame
- **users controller**: get body from IO
- **users controller**: allow assignment of admin attributes
- **root**: reuse db connection
- **logging**: update dependencies to fix logging
- **controller:authentications**: restrict to admin

### Refactor

- **logging**: base beneath self, rather than APP_NAME
- **controllers**: DRY out access to module state
- **controllers**: consistent error response
- **constants**: move constants to a seperate file
- **controller:cluster**: use `id` instead of `core_id`

## v1.21.0 (2021-03-03)

### Feat

- add logstash support
- **users**: find user using email or id

### Fix

- **controller:cluster**: empty array on key miss
- **config**: report logs in milliseconds only
- **controller:repositories**: force compile interface repositories

## v1.20.0 (2021-01-28)

### Feat

- **config**: verbose clustering logs behind PLACE_VERBOSE_CLUSTERING
- **controllers:users**: add a bulk group query endpoint

### Refactor

- **controllers**: use 400 over 422 for missing params
- **controllers**: save_and_respond accepts mutation block

## v1.18.3 (2021-01-21)

### Feat

- **controller:edge**: add CRUD, and token method
- **edge**: implement edge proxy
- **controller:edge**: implement connection manager

### Fix

- **controller:users**: pull String out of IO for double parse
- **controllers:user**: prevent privilege escalation via bulk assignment
- **controller:drivers**: use HTTP status type directly
- build action
- **controller:oauth_applications**: restrict to admin
- clashing route

### Refactor

- **controllers**: reduce redundant assignments
- **controller**: safe request body accessor
- **controller:cluster**: edge observability
- **controllers:repositories**: enum methods

## v1.18.1 (2020-12-03)

### Feat

- **metadata**: add support for editors based on roles
- **session**: provide some more error context to logs

### Fix

- docker compose test ([#69](https://github.com/PlaceOS/rest-api/pull/69))

### Refactor

- **controller:repositories**: use `limit` rather than `count` for commit listing

## v1.17.11 (2020-10-21)

### Fix

- **spec:helper**: correct order of imports

## v1.17.10 (2020-10-14)

### Feat

- **app**: add environment list behind `-e` or `--env`
- **metadata**: allow users to edit their metadata

### Fix

- **log**: register Log backends before deps have chance to log anything

### Refactor

- **session**: use exhaustive case for websocket messages

## v1.17.8 (2020-09-23)

### Feat

- allow guest access to zone details ([#59](https://github.com/PlaceOS/rest-api/pull/59))
- **exec error**: respond with JSON
- **exec error**: return failure details

### Fix

- **controller:modules**: check boolean param is nil, rather than truthy
- minor typos

### Refactor

- remove Hash kernel extension
- **controllers**: lazy getters
- **responders**: use `case ... in` when matching driver error codes

## v1.17.6 (2020-09-09)

### Feat

- **webhook**: include query params
- allow guests to get the details of the room
- allow signal to accept guest scopes
- **authorize!**: ensure correct scope is in use
- **app**: display commit and build time in logs

### Fix

- **webhook**: skip checking oauth scope
- **app.cr**: remove newline char from build time

### Refactor

- lazy getters

## v1.17.3 (2020-08-14)

## v1.17.2 (2020-08-14)

### Feat

- **users**: provide a method for updating admin attributes
- **user**: add scope to refresh request
- **users**: support for managing SSO resource tokens

### Fix

- **controllers:root**: skip setting of user_id for root
- **rest-api**: expires check is clearer
- **controller:metadata**: consistent updates to `details`
- **users**: return token after being refreshed
- **Dockerfile**: ensure valid certificates and timezone info
- **users**: ensure refresh token present
- **users**: resolve nilables
- **users**: ensure internals are present
- **controller:metadata**: default include parent metadata in children route
- **system-triggers**: missing exec enabled update param

### Refactor

- update placeos-models

## v1.16.4 (2020-07-15)

### Fix

- **controller:repositories**: allow edits to Interface repository URIs

## v1.16.3 (2020-07-15)

### Feat

- **controller:repositories**: support branch listing for interface repositories

### Fix

- **controller:systems**: run save callbacks on remove module
- **controller:repositories**: asynchronously pull Interface repositories

## v1.15.1 (2020-07-08)

### Feat

- **controller:metadata**: generic metadata controller
- **controller:system-triggers**: add a `complete` param for show and index

### Fix

- **modules**: don't double serialize exec result
- **webhook**: remove additional parsing from exec response
- **webhook**: response is double JSON parsed
- **webhook**: simplify exec style webhook
- **config**: TRIGGERS_URI optional
- **webhook**: add TRIGGER_URI ENV var
- **webhook**: triggers port
- **webhook**: skip authentication
- **metadata**: parent_id optional on create
- **controller:zone-metadata**: correctly generate filtered metadata
- **controller:systems**: filter by trigger_id

## v1.13.5 (2020-06-29)

### Feat

- allow users to be created for other domains
- add secrets and clean up constants

## v1.13.4 (2020-06-24)

## v1.13.3 (2020-06-22)

## v1.13.1 (2020-06-19)

### Feat

- **controller:systems**: add `emails` filter to index`

### Fix

- **controller:drivers**: synchronous recompile
- **app controller**: logger
- **config**: 0.35 logs
- **Log**: use `Log#setup`
- **controller:modules**: update neuroplastic

### Refactor

- **root**: use RubberSoul::Client
- **controllers**: set_collection_headers shortcut for fixed collections

## v1.12.0 (2020-06-16)

### Feat

- **controller:triggers**: add instances route

## v1.11.0 (2020-06-16)

### Feat

- allow querying for multiple email addresses
- **systems**: helper for finding by resource email

## v1.10.2 (2020-06-05)

## v1.10.0 (2020-06-03)

### Feat

- **controller:brokers**: implement Brokers controller
- use the shared discovery instance
- allow sending the bearer token via cookie

### Fix

- **spec:modules**: explicit overload fix

### Refactor

- rename `placeos-rest-api`

## v1.8.4 (2020-05-14)

## v1.8.3 (2020-05-13)

### Fix

- **controller:settings**: decrypt response for creates and updates

## v1.8.1 (2020-05-04)

### Feat

- **controller:repositories**: handle `Interface` type repositories

### Fix

- **controller:repositories**: upcase 'HEAD'

## v1.7.1 (2020-05-01)

### Feat

- **users controller**: add destroy method

### Fix

- **users controller**: @user is nilable

### Refactor

- migrate to Log

## v1.6.0 (2020-04-20)

### Feat

- **controller:drivers**: add core compilation status for the driver

### Fix

- **users controller**: user params come from request body

## v1.5.1 (2020-04-15)

### Feat

- **controller:drivers**: use HTTP codes
- **controllers**: add `../drivers/:id/compiled` and `../modules/:id/load`
- **dockerfile**: bump crystal version
- add support for crystal 0.34
- **dockerfile**: don't run process as root

### Fix

- displaying cluster details in various states
- displaying cluster details in various states

## v1.4.1 (2020-04-08)

## v1.4.0 (2020-04-06)

### Feat

- **controller:systems**: add `GET ../systems/:system_id/zones`
- **drivers**: add support for recompilation
- **systems**: add additional filters
- **oauth_apps**: add support for filtering by authority
- **controller:modules**: `complete` boolean param for `show` route
- **controller:root**: add `build_time` and `commit` fields for `GET /version`
- **zone_metadata**: allow use of put or post verbs
- **zone_metadata**: initial work metadata API
- **zones**: add filtering zones by parent
- **settings**: add `GET ../settings/:id/history`
- **controller:settings|modules**: implement `GET ../:id/settings`
- **modules**: include driver details in system_id request
- **root controller**: add signal endpoint
- **systems**: delete module to return control system
- **controllers:systems**: add/remove modules
- **system controller**: add key ordering to function listing
- **cluster controller**: introspect the cluster
- add timeout for repository pull
- **controller:repositories**: implement pull
- **session**: debug/ignore
- **root.cr**: add cluster details endpoint
- alias PATCH with PUT
- include methods for re-indexing elastic
- **Dockerfile**: build images using alpine
- improve authentication / authorisation
- **systems controller**: improve system edit error messages
- improve listing and pagination of data
- show error backtrack in development
- throw a 400 error for JSON parsing errors
- **Dockerfile**: build a minimal image
- **session**: add ping / pong support for JS clients
- **authentication crud**: adds routes for LDAP SAML and OAuth
- add domains and applications
- **repositories controller**: add driver details endpoint
- **repositories**: add driver listing and commit listing
- **repositories**: add support driver repository CRUD
- **webhooks**: initial work on trigger API
- **controllers webhook**: simplified webhook controller (wip)
- **controllers/modules**: exec

### Fix

- PUT route before actions
- **dockerfile**: typo in Dockerfile
- **controller:zone_metadata**: correct `find!` signature
- **utilities:responders**: fix double merge
- update model queries
- **controller:systems**: use `Model::Module.in_control_system` query
- **zone_metadata**: results array key is not nillable
- **zone metadata**: return value not required
- **zone metadata**: use each with object
- **zone metadata**: no requirement for `to_a`
- **zone metadata**: no requirement for `to_a`
- **zone_metadata**: enforce security on put verb
- **zone_metadata**: use database filter
- **zone_metadata**: use database filter
- **zone_metadata**: format and ameba cleanup
- **controller:systems**: honour `ignore_startstop` field for Module
- **systems**: fix response overload
- **systems**: execute request double encodes
- **zones**: comma seperate tags when filtering by tags
- **controller:application**: check `Content-Type` starts with media-type 'application/json'
- **system controller**: module delete routes
- change how modules are removed from systems
- **cluster controller**: error details are not strings
- **controllers:modules**: don't attempt to merge system attributes when module not associated
- **session**: debug messages include the severity
- **pagination**: next link now maintains query params
- **cluster controller**: map drivers not details
- **cluster controller**: paramater names
- **session**: send level in debug frames, struct response, close socket in `ignore`
- **session**: clean up websockets
- migrate request id to Int64
- **session.cr**: id is a uint64
- **config.cr**: compress hander does not work with websockets
- **controllers**: set `request_id` before authorization check
- **controller:systems**: raise if no core instance registered when consistent hashing
- **controllers**: correct PUT update route alias to include an id param
- **constants**: improved version extraction
- issues with user controller responses
- **systems controller**: precondition failed for missing version
- **system controller**: improve error messages
- **spec**: update to new result format
- **spec helper**: update to new result format
- check for next page of results
- **Docker**: use `-c` flag for health check
- **Dockerfile**: include the hosts file in image
- **Docker**: provide a simple health check option
- migrate to new discovery interface
- get_parts moving into RemoteDriver
- **repositories**: details method was named incorrectly
- **webhooks**: compile

### Refactor

- `ACAEngine` -> `PlaceOS`, `engine-api` -> `rest-api`
- **utils:severity_converter**: factor `SeverityConverter` out into its own file
- **controllers/zones**: remove unneccessary rescue block

### Perf

- use `reverse!` where appropriate
- **controller:systems**: prefer update over replace
- **controller:systems**: improve system module `running` state toggle query

## v1.3.0 (2019-12-04)

### BREAKING CHANGE

- paths for requests require a slight change

### Feat

- module exec, system exec, refactor System's remove route
- migrate to new error handler
- add support for triggers
- **controller/systems**: implement `/systems/:sys_id/types``
- **controllers/settings**: implement basic settings api logic
- **session**: session error
- **action-controller**: upgrade to v2.0
- **controllers/systems**: include core client
- **model/repository**: default to Type::Driver
- **logging**: scrub bearer_tokens and secrets from production logs
- **shard.yml config**: add and configure service discovery
- **model:module**: spec merging module settings
- **model:module**: add #merge_settings that respects settings hierarchy
- **models**: add settings module
- **model**: add driver_name field to Module

### Fix

- **config**: syntax error in logger initialisation
- actually send the error response in create bindings
- update lock file
- **session**: implement exec websocket request
- **root**: correct root path
- **systems**: update hound-dog discovery calls
- **session_manager**: use the global logger
- **model:module**: include driver to fix type resolution
- **user**: remove scrypt, discard password logic

### Refactor

- update tagged logs, remove casts scattered through controllers
- **controllers/systems**: update exec/state routes
- **session**: place class under ACAEngine namespace to reduce namespacing requirements
- **controllers/zones**: remove `data` look up on a zone
- **systems**: websocket api `/systems/bind` -> `/systems/control`
- remove `#not_nil!` in favour of `#as(T)`
- **spawn**: set same_thread in anticipation of multi-threading support
- **controllers/systems**: funcs -> functions, exec -> execute
- **models**: separate models
- **api**: change version routing "v1" -> "v2"
- Engine -> ACAEngine
