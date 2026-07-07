SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

KNOWN_SERVICES := db postgres redis
SERVICE_ARG := $(firstword $(filter $(KNOWN_SERVICES),$(MAKECMDGOALS)))
SERVICE := $(if $(SERVICE_ARG),$(SERVICE_ARG),db)
CANONICAL_SERVICE := $(if $(filter postgres,$(SERVICE)),db,$(SERVICE))
KNOWN_GOALS := help config serve db postgres redis config-db serve-db ensure-db-env validate-db-env preview-db-env ensure-db-config prepare-db-data-dir config-redis serve-redis ensure-redis-env validate-redis-env preview-redis-env ensure-redis-config prepare-redis-data-dirs
UNKNOWN_GOALS := $(filter-out $(KNOWN_GOALS),$(MAKECMDGOALS))

ifneq ($(UNKNOWN_GOALS),)
$(error Unknown make goal(s): $(UNKNOWN_GOALS))
endif

.PHONY: help config serve db postgres redis config-db serve-db ensure-db-env validate-db-env preview-db-env ensure-db-config prepare-db-data-dir config-redis serve-redis ensure-redis-env validate-redis-env preview-redis-env ensure-redis-config prepare-redis-data-dirs

help:
	@printf 'Usage:\n'
	@printf '  make config db     Generate Postgres config from host resources\n'
	@printf '  make serve db      Validate env, preview safe values, ensure config/data dir, start Postgres\n'
	@printf '  make config redis  Generate Redis configs from host resources\n'
	@printf '  make serve redis   Validate env, preview safe values, ensure config/data dirs, start Redis\n'
	@printf '  make ensure-db-env     Create/fill postgres/.env passwords when needed\n'
	@printf '  make ensure-redis-env  Create/fill redis/.env passwords when needed\n'
	@printf '\n'
	@printf 'Aliases:\n'
	@printf '  db and postgres both refer to the Postgres service\n'

config:
	@$(MAKE) --no-print-directory config-$(CANONICAL_SERVICE)

serve:
	@$(MAKE) --no-print-directory serve-$(CANONICAL_SERVICE)

db postgres redis:
	@:

config-db:
	@scripts/generate-postgres-config.sh

ensure-db-env:
	@scripts/postgres-env-check.sh ensure-env

validate-db-env:
	@scripts/postgres-env-check.sh validate

preview-db-env:
	@scripts/postgres-env-check.sh preview

ensure-db-config:
	@if [[ ! -s postgres/pg_config/postgresql.conf || ! -s postgres/pg_config/pg_hba.conf ]]; then \
		printf 'Postgres config is missing; running make config db\n'; \
		$(MAKE) --no-print-directory config db; \
	elif [[ scripts/generate-postgres-config.sh -nt postgres/pg_config/postgresql.conf || postgres/templates/postgresql.conf.tpl -nt postgres/pg_config/postgresql.conf || postgres/templates/pg_hba.conf.tpl -nt postgres/pg_config/pg_hba.conf || ( -f postgres/.env && postgres/.env -nt postgres/pg_config/postgresql.conf ) ]]; then \
		printf 'Postgres config inputs changed; running make config db\n'; \
		$(MAKE) --no-print-directory config db; \
	else \
		printf 'Postgres config exists: postgres/pg_config\n'; \
	fi

prepare-db-data-dir:
	@scripts/postgres-env-check.sh prepare-data-dir

serve-db:
	@scripts/postgres-env-check.sh ensure-env
	@scripts/postgres-env-check.sh validate
	@scripts/postgres-env-check.sh preview
	@$(MAKE) --no-print-directory ensure-db-config
	@$(MAKE) --no-print-directory prepare-db-data-dir
	@docker compose --env-file postgres/.env -f postgres/docker-compose.yml up -d

config-redis:
	@scripts/generate-redis-config.sh

ensure-redis-env:
	@scripts/redis-env-check.sh ensure-env

validate-redis-env:
	@scripts/redis-env-check.sh validate

preview-redis-env:
	@scripts/redis-env-check.sh preview

ensure-redis-config:
	@if [[ ! -s redis/redis_config/cache.conf || ! -s redis/redis_config/ws.conf || ! -s redis/redis_config/session.conf || ! -s redis/redis_config/queue.conf || ! -s redis/redis_config/compose.env ]]; then \
		printf 'Redis config is missing; running make config redis\n'; \
		$(MAKE) --no-print-directory config redis; \
	elif [[ scripts/generate-redis-config.sh -nt redis/redis_config/cache.conf || redis/templates/redis.conf.tpl -nt redis/redis_config/cache.conf || ( -f redis/.env && redis/.env -nt redis/redis_config/cache.conf ) || ( -f redis/.env && redis/.env -nt redis/redis_config/compose.env ) ]]; then \
		printf 'Redis config inputs changed; running make config redis\n'; \
		$(MAKE) --no-print-directory config redis; \
	else \
		printf 'Redis config exists: redis/redis_config\n'; \
	fi

prepare-redis-data-dirs:
	@scripts/redis-env-check.sh prepare-data-dirs

serve-redis:
	@scripts/redis-env-check.sh ensure-env
	@scripts/redis-env-check.sh validate
	@scripts/redis-env-check.sh preview
	@$(MAKE) --no-print-directory ensure-redis-config
	@$(MAKE) --no-print-directory prepare-redis-data-dirs
	@docker compose --env-file redis/.env --env-file redis/redis_config/compose.env -f redis/docker-compose.yml up -d
