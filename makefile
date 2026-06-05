# redis-rb test infrastructure
#
# Topologies are managed by docker-compose.yml and selected via Docker profiles.
# Override the Redis version with REDIS_VERSION=8.X.Y; the default tracks the
# latest stable patch in the redislabs/client-libs-test image series.
#
# Target names mirror the historical makefile so existing dev muscle memory and
# CI shell scripts keep working. Each one shells out to docker compose.

REDIS_VERSION  ?= 8.8.0
export REDIS_VERSION
TMP            := tmp
SOCKET_PATH    := ${TMP}/redis.sock

all: start_all test stop_all

${TMP}:
	@mkdir -p $@

start: ${TMP}
	@docker compose --profile standalone up -d --wait

stop:
	@docker compose --profile standalone down -v

start_slave: ${TMP}
	@docker compose --profile replica up -d --wait

stop_slave:
	@docker compose --profile replica down -v

start_sentinel: ${TMP}
	@docker compose --profile sentinel up -d --wait

stop_sentinel:
	@docker compose --profile sentinel down -v

# Healthchecks (cluster_state:ok) make wait_for_sentinel redundant; kept as a
# no-op for backward compatibility with anything that still depends on it.
wait_for_sentinel:
	@true

start_cluster:
	@docker compose --profile cluster up -d --wait

stop_cluster:
	@docker compose --profile cluster down -v

# Cluster init is performed by the image entrypoint (redis-cli --cluster create).
# Kept as a no-op so `make start_cluster create_cluster` still works.
create_cluster:
	@true

# Standalone instance with Redis modules (Redis Stack) for the module test suite. Override
# the image with REDIS_STACK_VERSION=rs-7.2.0-v20 (etc).
start_modules: ${TMP}
	@docker compose --profile modules up -d --wait

stop_modules:
	@docker compose --profile modules down -v

start_all: ${TMP}
	@docker compose --profile all up -d --wait

stop_all:
	@docker compose --profile all down -v

test:
	@env REDIS_SOCKET_PATH=${SOCKET_PATH} bundle exec rake test

clean: stop_all
	@rm -f ${SOCKET_PATH}

.PHONY: all test stop start stop_slave start_slave stop_sentinel start_sentinel \
	wait_for_sentinel stop_cluster start_cluster create_cluster stop_all \
	start_all start_modules stop_modules clean
