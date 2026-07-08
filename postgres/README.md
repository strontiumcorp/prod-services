# Postgres Production Service

Postgres is managed from the repository root.

```sh
make config db
make serve db
```

`db` and `postgres` are aliases, so `make config postgres` also works.

## What The Commands Do

`make config db` renders:

```text
postgres/pg_config/postgresql.conf
postgres/pg_config/pg_hba.conf
```

`make serve db` runs this flow:

```text
1. Create postgres/.env from .env.example if needed
2. Prompt to generate POSTGRES_PASSWORD if it is empty
3. Validate postgres/.env
4. Preview safe values such as database name, image, container name, port, CIDRs
5. Generate config if postgres/pg_config/*.conf is missing or stale
6. Create the configured host data directory if needed
7. Run Docker Compose with postgres/.env
```

## Tuning Model

The generator is
[scripts/generate-postgres-config.sh](../scripts/generate-postgres-config.sh).
It detects host RAM from `/proc/meminfo` and CPU cores from `nproc`.

Memory tuning keeps explicit host headroom:

```text
host_reserved_memory = total_memory * 10%
postgres_tuning_memory = total_memory - host_reserved_memory
```

The 10% reserve is for the host OS, Docker daemon, logging, monitoring, shell
sessions, and filesystem activity outside Postgres. Override it only when the
VM layout requires it:

```sh
POSTGRES_HOST_MEMORY_RESERVE_PERCENT=10
```

Generated memory formulas use `postgres_tuning_memory`, not total host memory:

```text
max_connections        = min(cpu_cores * 25, postgres_tuning_memory / 64MB, 200), floor 50
shared_buffers         = 25% of postgres_tuning_memory, rounded to 128MB, capped at 8GB
effective_cache_size   = 75% of postgres_tuning_memory, rounded to 128MB
maintenance_work_mem   = 1/16 of postgres_tuning_memory, rounded to 64MB, capped at 2GB
work_mem               = (remaining_memory / max_connections / 2), capped between 4MB and 64MB
```

`effective_cache_size` is a planner hint. It is not directly allocated memory.

## Environment

Required:

```sh
POSTGRES_PASSWORD=
```

Common values:

```sh
POSTGRES_USER=postgres
POSTGRES_DB=db_master
POSTGRES_BIND_ADDRESS=127.0.0.1
POSTGRES_HOST_PORT=5432
POSTGRES_CONTAINER_NAME=postgres
POSTGRES_IMAGE=postgres:18.4-alpine
POSTGRES_DATA_DIR=./data
POSTGRES_ALLOWED_CIDRS=10.1.0.0/24
```

`POSTGRES_BIND_ADDRESS` defaults to localhost so a new VM does not expose the
database on every network interface. For app VMs on a private network, set it
to the database VM's private IP and keep `POSTGRES_ALLOWED_CIDRS` limited to
the application network.

### Allowed CIDRs

`POSTGRES_ALLOWED_CIDRS` controls which remote IP ranges are written to
`pg_hba.conf`. CIDR means Classless Inter-Domain Routing. In practice, it is
the standard `address/prefix-length` notation for describing one IP address or
a range of IP addresses:

```text
network-or-host-address/prefix-length
```

The prefix length is how many bits of the address must match. IPv4 addresses
have 32 bits total, split into four 8-bit octets:

```text
10 . 1 . 0 . 202
8    8   8    8   bits
```

For IPv4, the prefix length must be from `/0` to `/32`. Larger numbers are
more specific. Dropping 8 bits loosens the range by one octet:

```text
/32 = all 32 bits match   = one exact host
/24 = 32 - 8 bits match   = first 3 octets match
/16 = 32 - 8 - 8 match    = first 2 octets match
```

Common private-network examples:

```sh
# Allow exactly one app VM.
POSTGRES_ALLOWED_CIDRS=10.1.0.202/32

# Allow any host whose IP starts with 10.1.0.
POSTGRES_ALLOWED_CIDRS=10.1.0.0/24

# Allow any host whose IP starts with 10.1.
POSTGRES_ALLOWED_CIDRS=10.1.0.0/16
```

`10.1.0.202/32` is an exact host address, so it only allows
`10.1.0.202`. `10.1.0.0/24` allows the `10.1.0.x` network, and
`10.1.0.0/16` allows the wider `10.1.x.x` network.

Do not use netmask octets as the CIDR prefix. For example,
`10.1.0.0/255` is invalid. If the netmask is `255.255.255.0`, use `/24`.

The default image tracks the latest stable major version we selected for this
repo. For an existing data directory, do not move across Postgres major
versions without a real major-version upgrade or dump/restore plan.

## Storage

`POSTGRES_DATA_DIR` is a host bind mount, not a Compose named volume. This is
intentional: `docker compose down -v` removes named volumes, but it does not
delete a normal host directory.

The default `./data` path resolves relative to `postgres/docker-compose.yml`,
so it becomes `postgres/data/`. For production VMs, an absolute path is also
reasonable:

```sh
POSTGRES_DATA_DIR=/srv/prod-services/postgres/data
```

## Runtime Knobs

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

Do not hand-edit generated files in `postgres/pg_config/`. Edit
`postgres/.env` or templates in `postgres/templates/`, then run
`make config db`.
