# Triggers API:

Has the regular CRUD methods for the model

```
/api/engine/v2/triggers/
```

## Model:

https://github.com/placeos/models/blob/master/src/models/trigger.cr

```yaml
{
  "name": "string",
  "description": "string",
  "conditions": {
    "comparisons": [Array of Comparison objects],
    "time_dependents": [Array of Time objects]
  },
  "actions": {
    "functions": [Array of functions to call],
    "mailers": [Array of emails to send]
  },

  # Should instances of this trigger enable a webhook?
  "enable_webhook": true,

  # (the verbs supported by this web hook when enabled - GET POST PUT PATCH DELETE)
  "supported_methods": ["POST", "GET"],
  "important": false
}
```

### Comparison objects

Can compare a constant or a binding / status variable. Left here is a binding and right is a constant

```yaml
{
  "left": {
    "mod": "Display_1",
    "status": "power",
    # sub keys of the status if status was a hash (array of strings)
    # can implement as a comma separated text field
    "keys": []
  },
  "operator": "",
  "right": "constant, can be a string, a num 1212.34 or a bool true / false"
}
```

Constant can be one of: `Int | Float | String | Bool`


### Time Dependents objects

```yaml
{
  "type": "at or cron",
  # use when type == at, is a unix epoch in seconds
  "time": 12345689,
  # use when type == cron, a valid cron string
  "cron": "15 5 * * 1,3,5"
}
```


### Function object

The valid functions and function arguments can be grabbed from the API

```yaml
{
  "mod": "Driver_2",
  "method": "method_name",
  "args": {
    "arg_name": "arg value (any valid JSON type)"
  }
}
```


### Email object

```yaml
{
  "emails": ["email1@gmail.com", "email2@gmail.com"],
  "content": "What the email should say"
}
```
