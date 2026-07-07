# Production Services

Reusable Docker Compose services for production VMs. Postgres and Redis are
wired into the shared workflow.

## Quick Start

```sh
cp postgres/.env.example postgres/.env
vim postgres/.env
make config db
make serve db
```

Redis uses the same pattern:

```sh
cp redis/.env.example redis/.env
vim redis/.env
make config redis
make serve redis
```

`make config db` renders Postgres config files from templates and host
resources. `make serve db` validates `postgres/.env`, prints a safe preview of
non-sensitive values, generates config if it is missing, prepares the host data
directory, then starts Postgres.

If `.env` is missing or password fields are empty, `make config ...` and
`make serve ...` prompt before generating random passwords and writing them to
the service `.env` file. For non-interactive setup, run the env bootstrap
directly with `--yes`:

```sh
scripts/postgres-env-check.sh ensure-env --yes
scripts/redis-env-check.sh ensure-env --yes
```

## Commands

```sh
make config db
```

Generates:

```text
postgres/pg_config/postgresql.conf
postgres/pg_config/pg_hba.conf
```

```sh
make serve db
```

Runs these steps:

```text
1. Validate postgres/.env
2. Preview safe values such as database name, image, container name, port, CIDRs
3. Generate Postgres config if postgres/pg_config/*.conf is missing
4. Create the configured host data directory if needed
5. Run docker compose with postgres/.env
```

`db` and `postgres` are aliases, so `make config postgres` also works.

```sh
make ensure-db-env
```

Creates `postgres/.env` from `postgres/.env.example` when missing and fills
`POSTGRES_PASSWORD` when it is empty.

```sh
make config redis
```

Generates:

```text
redis/redis_config/cache.conf
redis/redis_config/session.conf
redis/redis_config/queue.conf
redis/redis_config/ws.conf
redis/redis_config/compose.env
```

```sh
make serve redis
```

Runs these steps:

```text
1. Validate redis/.env
2. Preview safe values such as image, bind address, ports, names, data dirs
3. Generate Redis config if redis/redis_config/* is missing
4. Create configured host data directories if needed
5. Run docker compose with redis/.env and generated compose.env
```

```sh
make ensure-redis-env
```

Creates `redis/.env` from `redis/.env.example` when missing and fills any empty
Redis password fields.

## Postgres Tuning

The generator is [scripts/generate-postgres-config.sh](scripts/generate-postgres-config.sh).
It detects host RAM from `/proc/meminfo` and CPU cores from `nproc`.

Memory tuning keeps explicit headroom:

```text
host_reserved_memory = total_memory * 10%
postgres_tuning_memory = total_memory - host_reserved_memory
```

The 10% reserve is for the host OS, Docker daemon, logging, monitoring, shell
sessions, and filesystem activity outside Postgres. Change it only when the VM
layout requires it:

```sh
POSTGRES_HOST_MEMORY_RESERVE_PERCENT=10
```

Current generated memory formulas use `postgres_tuning_memory`, not total host
memory:

```text
max_connections        = min(cpu_cores * 25, postgres_tuning_memory / 64MB, 200), floor 50
shared_buffers         = 25% of postgres_tuning_memory, rounded to 128MB, capped at 8GB
effective_cache_size   = 75% of postgres_tuning_memory, rounded to 128MB
maintenance_work_mem   = 1/16 of postgres_tuning_memory, rounded to 64MB, capped at 2GB
work_mem               = (remaining_memory / max_connections / 2), capped between 4MB and 64MB
```

`effective_cache_size` is a planner hint. It is not directly allocated memory.

## Postgres Environment

Required:

```sh
POSTGRES_PASSWORD=
```

Common non-sensitive values:

```sh
POSTGRES_USER=postgres
POSTGRES_DB=db_master
POSTGRES_BIND_ADDRESS=127.0.0.1
POSTGRES_HOST_PORT=5432
POSTGRES_CONTAINER_NAME=postgres
POSTGRES_IMAGE=postgres:18.4-alpine
POSTGRES_DATA_DIR=./data
POSTGRES_ALLOWED_CIDRS=10.1.0.0/16
```

`POSTGRES_BIND_ADDRESS` defaults to localhost to avoid accidentally exposing a
new VM's database on every network interface. For app VMs on a private network,
set this to the database VM's private IP and keep `POSTGRES_ALLOWED_CIDRS`
limited to the application network.

`POSTGRES_DATA_DIR` is a host bind mount, not a Compose named volume. This is
intentional: `docker compose down -v` removes named volumes, but it does not
delete a normal host directory. The default `./data` resolves relative to
`postgres/docker-compose.yml`, so it becomes `postgres/data/`. For production
VMs, an absolute path is also reasonable:

```sh
POSTGRES_DATA_DIR=/srv/prod-services/postgres/data
```

Runtime hardening knobs:

```sh
POSTGRES_SHM_SIZE=1gb
POSTGRES_PIDS_LIMIT=4096
POSTGRES_STOP_GRACE_PERIOD=60s
POSTGRES_LOG_MAX_SIZE=100m
POSTGRES_LOG_MAX_FILE=5
```

Optional detection overrides:

```sh
POSTGRES_MEMORY_MB=16384
POSTGRES_CPU_CORES=8
```

Optional tuning overrides:

```sh
POSTGRES_MAX_CONNECTIONS=200
POSTGRES_SHARED_BUFFERS=4GB
POSTGRES_EFFECTIVE_CACHE_SIZE=12GB
POSTGRES_WORK_MEM=32MB
POSTGRES_MAINTENANCE_WORK_MEM=1GB
```

Do not hand-edit generated files in `postgres/pg_config/`; edit `.env` or the
templates in `postgres/templates/`, then run `make config db`.

## Redis Tuning

The generator is [scripts/generate-redis-config.sh](scripts/generate-redis-config.sh).
It detects host RAM from `/proc/meminfo` and CPU cores from `nproc`.

Redis keeps the same host headroom model as Postgres, then uses a configurable
slice of the remaining memory for Redis `maxmemory` values:

```text
host_reserved_memory = total_memory * 10%
redis_tuning_memory = total_memory - host_reserved_memory
redis_maxmemory_budget = redis_tuning_memory * 25%
```

The default 25% Redis budget is intentionally conservative because Redis
memory can temporarily grow above `maxmemory` during persistence, replication,
large deletes, or allocator fragmentation. Override it for Redis-dedicated VMs:

```sh
REDIS_MEMORY_BUDGET_PERCENT=25
```

The generated budget is distributed across the four Redis roles:

```text
cache      30%  allkeys-lru, no persistence
websocket   5%  allkeys-lru, no persistence
session    13%  volatile-ttl, no persistence
queue      52%  noeviction, AOF + RDB persistence
```

The generator also writes `redis/redis_config/compose.env` with container
`mem_limit` values. Compose loads both `redis/.env` and that generated file
when running `make serve redis`.

Redis data directories are host bind mounts, not Compose named volumes, so
`docker compose down -v` will not delete them:

```sh
REDIS_CACHE_DATA_DIR=./data/cache
REDIS_SESSION_DATA_DIR=./data/session
REDIS_QUEUE_DATA_DIR=./data/queue
REDIS_WS_DATA_DIR=./data/ws
```

The queue instance is the durable one. Cache, websocket, and session instances
are configured without AOF/RDB persistence by default.

Redis generated config files include `requirepass` values from `redis/.env`.
They are ignored by git. Do not hand-edit files in `redis/redis_config/`; edit
`.env` or `redis/templates/`, then run `make config redis`.
