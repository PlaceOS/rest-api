# Cluster API:

Provides task manager style introspection into the cluster

```
/api/engine/v2/cluster/
```

## Get an overview of the Cores in the cluster

These are the "Core" driver managers, i.e. where all the drivers reside

GET http://localhost:8080/api/engine/v2/cluster?include_status=true

```yaml
[
  {
    "id": "01E2PRBSNE4GXM9WGVM7M3KEZX",
    "compiled_drivers": [
      "drivers_place_private_helper_fe33588"
    ],
    "available_repositories": [
      "drivers",
      "place-drivers"
    ],
    "running_drivers": 1,
    "module_instances": 1,

    # These are the list of errors
    "unavailable_repositories": [],
    "unavailable_drivers": [],
    "hostname": "core",
    "cpu_count": 3,

    # % CPU usage as a float
    "core_cpu": 0,
    "total_cpu": 0,

    # total memory, total memory usage, this process's usage
    "memory_total": 8155620,
    "memory_usage": 3028124,
    "core_memory": 3028124
  }
]
```


## Get the details of a core

These are the processes being managed by the core

GET http://localhost:8080/api/engine/v2/cluster/01E2PRBSNE4GXM9WGVM7M3KEZX?include_status=true

```yaml
[
  {
    # This is the process name
    "driver": "/app/bin/drivers/drivers_place_private_helper_fe33588",
    # module ids that are running on the process
    "modules": [
      "mod-ETbLjPMTRfb"
    ],
    "running": true,
    "module_instances": 1,
    "last_exit_code": 0,
    "launch_count": 1,
    "launch_time": 1583459286,
    "percentage_cpu": 0,
    "memory_total": 8155620,
    "memory_usage": 92468
  }
]
```


## Kill a process

Terminates a process on the core causing core to re-launch the process

DELETE http://localhost:8080/api/engine/v2/cluster/01E2PRBSNE4GXM9WGVM7M3KEZX?driver=/app/bin/drivers/drivers_place_private_helper_fe33588
