REDIS_BRANCH       ?= 6.0
TMP                := tmp
BUILD_TLS          := no
BUILD_DIR          := ${TMP}/cache/redis-${REDIS_BRANCH}
TARBALL            := ${TMP}/redis-${REDIS_BRANCH}.tar.gz
BINARY             := ${BUILD_DIR}/src/redis-server
REDIS_CLIENT       := ${BUILD_DIR}/src/redis-cli
REDIS_TRIB         := ${BUILD_DIR}/src/redis-trib.rb
PID_PATH           := ${BUILD_DIR}/redis.pid
SOCKET_PATH        := ${BUILD_DIR}/redis.sock
PORT               := 6381
SLAVE_PORT         := 6382
TLS_PORT           := 6383
SLAVE_PID_PATH     := ${BUILD_DIR}/redis_slave.pid
SLAVE_SOCKET_PATH  := ${BUILD_DIR}/redis_slave.sock
HA_GROUP_NAME      := master1
SENTINEL_PORTS     := 6400 6401 6402
SENTINEL_PID_PATHS := $(addprefix ${TMP}/redis,$(addsuffix .pid,${SENTINEL_PORTS}))
CLUSTER_PORTS      := 7000 7001 7002 7003 7004 7005
CLUSTER_PID_PATHS  := $(addprefix ${TMP}/redis,$(addsuffix .pid,${CLUSTER_PORTS}))
CLUSTER_CONF_PATHS := $(addprefix ${TMP}/nodes,$(addsuffix .conf,${CLUSTER_PORTS}))
CLUSTER_ADDRS      := $(addprefix 127.0.0.1:,${CLUSTER_PORTS})

define kill-redis
  (ls $1 > /dev/null 2>&1 && kill $$(cat $1) && rm -f $1) || true
endef

all: start_all test stop_all

start_all: start start_slave start_sentinel wait_for_sentinel start_cluster create_cluster

stop_all: stop_sentinel stop_slave stop stop_cluster

${TMP}:
	@mkdir -p $@

${BINARY}: ${TMP}
	@env BUILD_TLS=${BUILD_TLS} bin/build ${REDIS_BRANCH} $<

test:
	@env SOCKET_PATH=${SOCKET_PATH} bundle exec rake test

stop:
	@$(call kill-redis,${PID_PATH})

start: ${BINARY}
ifeq ($(BUILD_TLS),yes)
	@$<\
		--daemonize        yes\
		--pidfile          ${PID_PATH}\
		--port             ${PORT}\
		--unixsocket       ${SOCKET_PATH}\
		--tls-port         ${TLS_PORT}\
		--tls-cert-file    ./test/support/ssl/trusted-cert.crt\
		--tls-key-file     ./test/support/ssl/trusted-cert.key\
		--tls-ca-cert-file ./test/support/ssl/trusted-ca.crt
else
	@$<\
		--daemonize  yes\
		--pidfile    ${PID_PATH}\
		--port       ${PORT}\
		--unixsocket ${SOCKET_PATH}
endif

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
		echo 'sentinel monitor                 ${HA_GROUP_NAME} 127.0.0.1 ${PORT} 2' >> $$conf;\
		echo 'sentinel down-after-milliseconds ${HA_GROUP_NAME} 5000'                >> $$conf;\
		echo 'sentinel failover-timeout        ${HA_GROUP_NAME} 30000'               >> $$conf;\
		echo 'sentinel parallel-syncs          ${HA_GROUP_NAME} 1'                   >> $$conf;\
		${BINARY} $$conf\
			--daemonize yes\
			--pidfile   ${TMP}/redis$$port.pid\
			--port      $$port\
			--sentinel;\
	done

wait_for_sentinel:
	@for port in ${SENTINEL_PORTS}; do\
		while : ; do\
			if [ $$(${REDIS_CLIENT} -p $${port} SENTINEL SLAVES ${HA_GROUP_NAME} | wc -l) -gt 1 ]; then\
				break;\
			fi;\
			echo 'Waiting for Redis sentinel to be ready...';\
			sleep 1;\
		done;\
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
