# Production Services

Reusable Docker Compose services for production VMs. Run commands from the
repository root.

## Quick Start

Postgres:

```sh
make config db
make serve db
```

Redis:

```sh
make config redis
make serve redis
```

On the first run, the scripts can create the service `.env` file from
`.env.example` and generate random passwords for any empty password fields.
`make serve ...` validates the `.env`, prints a safe preview of non-sensitive
settings, generates missing config, prepares host data directories, then starts
Docker Compose.

To edit values manually before running the commands:

```sh
cp postgres/.env.example postgres/.env
cp redis/.env.example redis/.env
```

## Commands

```sh
make help
make config db
make serve db
make config redis
make serve redis
make ensure-db-env
make ensure-redis-env
```

`db` and `postgres` are aliases, so `make config postgres` also works.

For non-interactive env bootstrap:

```sh
scripts/postgres-env-check.sh ensure-env --yes
scripts/redis-env-check.sh ensure-env --yes
```

## Generated Files

```text
postgres/pg_config/
redis/redis_config/
```

Generated config files are ignored by git. Redis generated configs include
`requirepass` values from `redis/.env`, so treat `redis/redis_config/` as
sensitive local output.

## Service Docs

- [Postgres production service](postgres/README.md)
- [Redis production service](redis/README.md)
