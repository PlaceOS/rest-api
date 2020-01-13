# Repositories API:

Supports standard CRUD methods for the model

```
/api/engine/v2/repositories/
```


## Model:

https://github.com/aca-labs/crystal-engine-models/blob/master/src/engine-models/repository.cr#L18-L25

```
{
  "name": "string", (required)
  "folder_name": "string", (required)
  "description": "string",
  "uri": "string", (required)
  "commit_hash": "string", (always send `"head"` don't give user the option to input)
  "type": 0 or 1
}
```

type `0` == Driver, type `1` == Interface

Where Interface is like a link to a www UI repository and Driver is a driver repo


## Discovery Methods:

* Get the list of drivers in a repository: `/api/engine/v2/repositories/:repo_id/drivers`
  * Returns an array of drivers: `["path/to/file.cr"]`
* Get the list of commits for a driver: `/api/engine/v2/repositories/:repo_id/commits?driver=URL_escaped_driver_name_from_the_drivers_request`
  * Returns an array of: `[{commit:, date:, author:, subject:}]`
* Get the details of a driver: `/api/engine/v2/repositories/:repo_id/details?driver=URL_escaped_driver_name_from_the_drivers_request&commit=selected_commit_hash`
  * Returns:
https://github.com/aca-labs/crystal-engine-driver/blob/master/docs/command_line_options.md#discovery-and-defaults
