# Postgres Production Service

Postgres is managed from the repository root.

```sh
cp postgres/.env.example postgres/.env
vim postgres/.env
make config db
make serve db
```

The generated config files in `pg_config/` come from `templates/`. They are
tuned from host RAM and CPU, with 10% of RAM reserved for the host and Docker.
Postgres data is stored in the host directory configured by
`POSTGRES_DATA_DIR`, which protects it from accidental `docker compose down -v`
runs that would remove named volumes.

See the root [README](../README.md) for the full command flow and tuning
calculation.
