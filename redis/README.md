# Redis Production Service

Redis is managed from the repository root.

```sh
cp redis/.env.example redis/.env
vim redis/.env
make config redis
make serve redis
```

`make config redis` generates role-specific Redis config files in
`redis_config/` plus `redis_config/compose.env` for generated container memory
limits.

The four Redis roles are:

```text
redis-cache    evictable cache, allkeys-lru, no persistence
redis-ws       websocket/broadcast state, allkeys-lru, no persistence
redis-session  session store, volatile-ttl, no persistence
redis-queue    durable queue, noeviction, AOF + RDB persistence
```

Data is stored in host directories configured by `REDIS_*_DATA_DIR`, which
protects it from accidental `docker compose down -v` runs that remove named
volumes.

See the root [README](../README.md) for the full command flow and tuning
calculation.
