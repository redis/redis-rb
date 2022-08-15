REDIS_BRANCH       ?= 7.0
ROOT_DIR           :=$(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
TMP                := tmp
CONF               := ${ROOT_DIR}/test/support/conf/redis-${REDIS_BRANCH}.conf
BUILD_DIR          := ${TMP}/cache/redis-${REDIS_BRANCH}
TARBALL            := ${TMP}/redis-${REDIS_BRANCH}.tar.gz
BINARY             := ${BUILD_DIR}/src/redis-server
REDIS_CLIENT       := ${BUILD_DIR}/src/redis-cli
REDIS_TRIB         := ${BUILD_DIR}/src/redis-trib.rb
PID_PATH           := ${BUILD_DIR}/redis.pid
SOCKET_PATH        := ${TMP}/redis.sock
PORT               := 6381
SLAVE_PORT         := 6382
SLAVE_PID_PATH     := ${BUILD_DIR}/redis_slave.pid
SLAVE_SOCKET_PATH  := ${BUILD_DIR}/redis_slave.sock
HA_GROUP_NAME      := master1
SENTINEL_PORTS     := 6400 6401 6402
SENTINEL_PID_PATHS := $(addprefix ${TMP}/redis,$(addsuffix .pid,${SENTINEL_PORTS}))
CLUSTER_PORTS      := 16380 16381 16382 16383 16384 16385
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
	@bin/build ${REDIS_BRANCH} $<

test:
	@env REDIS_SOCKET_PATH=${SOCKET_PATH} bundle exec rake test

stop:
	@$(call kill-redis,${PID_PATH});\

start: ${BINARY}
	@cp ${CONF} ${TMP}/redis.conf; \
	${BINARY} ${TMP}/redis.conf \
		--daemonize  yes\
		--pidfile    ${PID_PATH}\
		--port       ${PORT}\
		--unixsocket ${SOCKET_PATH}

stop_slave:
	@$(call kill-redis,${SLAVE_PID_PATH})

start_slave: start
	@${BINARY}\
		--daemonize  yes\
		--pidfile    ${SLAVE_PID_PATH}\
		--port       ${SLAVE_PORT}\
		--unixsocket ${SLAVE_SOCKET_PATH}\
		--slaveof    127.0.0.1 ${PORT}

stop_sentinel: stop_slave stop
	@$(call kill-redis,${SENTINEL_PID_PATHS})
	@rm -f ${TMP}/sentinel*.conf || true

start_sentinel: start start_slave
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

wait_for_sentinel: MAX_ATTEMPTS_FOR_WAIT ?= 60
wait_for_sentinel:
	@for port in ${SENTINEL_PORTS}; do\
		i=0;\
		while : ; do\
			if [ $${i} -ge ${MAX_ATTEMPTS_FOR_WAIT} ]; then\
				echo "Max attempts exceeded: $${i} times";\
				exit 1;\
			fi;\
			if [ $$(${REDIS_CLIENT} -p $${port} SENTINEL SLAVES ${HA_GROUP_NAME} | wc -l) -gt 1 ]; then\
				break;\
			fi;\
			echo 'Waiting for Redis sentinel to be ready...';\
			sleep 1;\
			i=$$(( $${i}+1 ));\
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
			--appendonly           no\
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
