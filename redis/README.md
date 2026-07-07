# Redis Production Service

Redis is managed from the repository root.

```sh
make config redis
make serve redis
```

## What The Commands Do

`make config redis` renders:

```text
redis/redis_config/cache.conf
redis/redis_config/session.conf
redis/redis_config/queue.conf
redis/redis_config/ws.conf
redis/redis_config/compose.env
```

`make serve redis` runs this flow:

```text
1. Create redis/.env from .env.example if needed
2. Prompt to generate empty Redis password values
3. Validate redis/.env
4. Preview safe values such as image, bind address, ports, names, and data dirs
5. Generate config if redis/redis_config/* is missing or stale
6. Create configured host data directories if needed
7. Run Docker Compose with redis/.env and generated compose.env
```

## Tuning Model

The generator is
[scripts/generate-redis-config.sh](../scripts/generate-redis-config.sh). It
detects host RAM from `/proc/meminfo` and CPU cores from `nproc`.

Redis uses the same host headroom model as Postgres, then gives Redis a
configurable slice of the remaining memory:

```text
host_reserved_memory = total_memory * 10%
redis_tuning_memory = total_memory - host_reserved_memory
redis_maxmemory_budget = redis_tuning_memory * 70%
```

The 10% reserve is for the host OS, Docker daemon, logging, monitoring, shell
sessions, and filesystem activity outside Redis. The default 70% Redis budget
uses most of the remaining memory for Redis while leaving 30% for filesystem
cache, persistence overhead, allocator fragmentation, Docker, and other host
activity.

For Redis-dedicated VMs, the defaults are:

```sh
REDIS_HOST_MEMORY_RESERVE_PERCENT=10
REDIS_MEMORY_BUDGET_PERCENT=70
```

The generated budget is distributed across the four Redis roles:

```text
cache      30%  allkeys-lru, no persistence
websocket   5%  allkeys-lru, no persistence
session    13%  volatile-ttl, no persistence
queue      52%  noeviction, AOF + RDB persistence
```

## Redis Roles

```text
redis-cache    evictable cache, allkeys-lru, no persistence
redis-ws       websocket/broadcast state, allkeys-lru, no persistence
redis-session  session store, volatile-ttl, no persistence
redis-queue    durable queue, noeviction, AOF + RDB persistence
```

Only the queue instance is durable by default. Cache, websocket, and session
instances are configured without AOF/RDB persistence.

## Why compose.env Exists

`redis/redis_config/compose.env` contains generated container `mem_limit`
values. Docker Compose must resolve `mem_limit` before containers start, so it
cannot read those values from the generated Redis `.conf` files inside the
container.

Keeping these values in a generated `compose.env` also keeps human-owned
settings in `redis/.env` clean. `compose.env` is non-sensitive generated output
and can be recreated with `make config redis`.

`make serve redis` loads both files:

```sh
docker compose --env-file redis/.env --env-file redis/redis_config/compose.env -f redis/docker-compose.yml up -d
```

## Compose Layout

`redis/docker-compose.yml` uses shared `x-*` extension blocks and YAML anchors
for common Redis service settings. This keeps the compose file in one file
without duplicating the hardened runtime block across all four Redis services.

The `x-*` blocks stay above `services` because YAML anchors must be defined
before they are referenced. Moving `services` above those blocks while keeping
anchors would make Docker Compose fail with an unknown-anchor error. If we ever
need `services` visually first, the practical option is to duplicate the shared
settings or use a different Compose pattern.

Put shared runtime hardening changes in `x-redis-common`; keep each service
block limited to role-specific ports, memory limits, data directories, and
config mounts.

## Environment

Common values:

```sh
REDIS_IMAGE=redis:8.8.0-alpine
REDIS_BIND_ADDRESS=127.0.0.1
REDIS_CACHE_HOST_PORT=6379
REDIS_SESSION_HOST_PORT=6380
REDIS_QUEUE_HOST_PORT=6381
REDIS_WS_HOST_PORT=6382
REDIS_CACHE_DATA_DIR=./data/cache
REDIS_SESSION_DATA_DIR=./data/session
REDIS_QUEUE_DATA_DIR=./data/queue
REDIS_WS_DATA_DIR=./data/ws
```

Required passwords:

```sh
REDIS_CACHE_PASSWORD=
REDIS_SESSION_PASSWORD=
REDIS_QUEUE_PASSWORD=
REDIS_WS_PASSWORD=
```

The default image tracks the latest stable Redis image we selected for this
repo. Review release notes before changing it on an existing production VM.

## Storage

Redis data directories are host bind mounts, not Compose named volumes, so
`docker compose down -v` will not delete them:

```sh
REDIS_CACHE_DATA_DIR=./data/cache
REDIS_SESSION_DATA_DIR=./data/session
REDIS_QUEUE_DATA_DIR=./data/queue
REDIS_WS_DATA_DIR=./data/ws
```

For production VMs, absolute paths are also reasonable:

```sh
REDIS_CACHE_DATA_DIR=/srv/prod-services/redis/cache
REDIS_SESSION_DATA_DIR=/srv/prod-services/redis/session
REDIS_QUEUE_DATA_DIR=/srv/prod-services/redis/queue
REDIS_WS_DATA_DIR=/srv/prod-services/redis/ws
```

Generated Redis config files include `requirepass` values from `redis/.env`.
They are ignored by git. Do not hand-edit files in `redis/redis_config/`; edit
`redis/.env` or `redis/templates/`, then run `make config redis`.
