REDIS_BRANCH       ?= 5.0
TMP                := tmp
BUILD_DIR          := ${TMP}/cache/redis-${REDIS_BRANCH}
TARBALL            := ${TMP}/redis-${REDIS_BRANCH}.tar.gz
BINARY             := ${BUILD_DIR}/src/redis-server
REDIS_CLIENT       := ${BUILD_DIR}/src/redis-cli
REDIS_TRIB         := ${BUILD_DIR}/src/redis-trib.rb
PID_PATH           := ${BUILD_DIR}/redis.pid
SOCKET_PATH        := ${BUILD_DIR}/redis.sock
PORT               := 6381
SLAVE_PORT         := 6382
SLAVE_PID_PATH     := ${BUILD_DIR}/redis_slave.pid
SLAVE_SOCKET_PATH  := ${BUILD_DIR}/redis_slave.sock
SENTINEL_PORTS     := 6400 6401 6402
SENTINEL_PID_PATHS := $(addprefix ${TMP}/redis,$(addsuffix .pid,${SENTINEL_PORTS}))
CLUSTER_PORTS      := 7000 7001 7002 7003 7004 7005
CLUSTER_PID_PATHS  := $(addprefix ${TMP}/redis,$(addsuffix .pid,${CLUSTER_PORTS}))
CLUSTER_CONF_PATHS := $(addprefix ${TMP}/nodes,$(addsuffix .conf,${CLUSTER_PORTS}))
CLUSTER_ADDRS      := $(addprefix 127.0.0.1:,${CLUSTER_PORTS})

define kill-redis
  (ls $1 > /dev/null 2>&1 && kill $$(cat $1) && rm -f $1) || true
endef

all:
	@make --no-print-directory start_all
	@make --no-print-directory test
	@make --no-print-directory stop_all

start_all:
	@make --no-print-directory start
	@make --no-print-directory start_slave
	@make --no-print-directory start_sentinel
	@make --no-print-directory start_cluster
	@make --no-print-directory create_cluster

stop_all:
	@make --no-print-directory stop_sentinel
	@make --no-print-directory stop_slave
	@make --no-print-directory stop
	@make --no-print-directory stop_cluster

${TMP}:
	@mkdir -p $@

${BINARY}: ${TMP}
	@bin/build ${REDIS_BRANCH} $<

test: 
	@env SOCKET_PATH=${SOCKET_PATH} bundle exec rake test

stop:
	@$(call kill-redis,${PID_PATH})

start: ${BINARY}
	@${BINARY}\
		--daemonize  yes\
		--pidfile    ${PID_PATH}\
		--port       ${PORT}\
		--unixsocket ${SOCKET_PATH}

stop_slave:
	@$(call kill-redis,${SLAVE_PID_PATH})

start_slave: ${BINARY}
	@${BINARY}\
		--daemonize  yes\
		--pidfile    ${SLAVE_PID_PATH}\
		--port       ${SLAVE_PORT}\
		--unixsocket ${SLAVE_SOCKET_PATH}\
		--slaveof    127.0.0.1 ${PORT}

stop_sentinel:
	@$(call kill-redis,${SENTINEL_PID_PATHS})
	@rm -f ${TMP}/sentinel*.conf || true

start_sentinel: ${BINARY}
	@for port in ${SENTINEL_PORTS}; do\
		conf=${TMP}/sentinel$$port.conf;\
		touch $$conf;\
		echo '' >  $$conf;\
		echo 'sentinel monitor                 master1 127.0.0.1 ${PORT} 2' >> $$conf;\
		echo 'sentinel down-after-milliseconds master1 5000'                >> $$conf;\
		echo 'sentinel failover-timeout        master1 30000'               >> $$conf;\
		echo 'sentinel parallel-syncs          master1 1'                   >> $$conf;\
		${BINARY} $$conf\
			--daemonize yes\
			--pidfile   ${TMP}/redis$$port.pid\
			--port      $$port\
			--sentinel;\
	done

stop_cluster:
	@$(call kill-redis,${CLUSTER_PID_PATHS})
	@rm -f appendonly.aof || true
	@rm -f ${CLUSTER_CONF_PATHS} || true

start_cluster: ${BINARY}
	@for port in ${CLUSTER_PORTS}; do\
		${BINARY}\
			--daemonize            yes\
			--appendonly           yes\
			--cluster-enabled      yes\
			--cluster-config-file  ${TMP}/nodes$$port.conf\
			--cluster-node-timeout 5000\
			--pidfile              ${TMP}/redis$$port.pid\
			--port                 $$port\
			--unixsocket           ${TMP}/redis$$port.sock;\
	done

create_cluster:
	@bin/cluster_creator ${CLUSTER_ADDRS}

clean:
	@(test -d ${BUILD_DIR} && cd ${BUILD_DIR}/src && make clean distclean) || true

.PHONY: all test stop start stop_slave start_slave stop_sentinel start_sentinel\
	stop_cluster start_cluster create_cluster stop_all start_all clean
