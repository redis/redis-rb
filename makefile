TEST_FILES         := $(shell find ./test -name *_test.rb -type f)
REDIS_BRANCH       ?= unstable
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
NODE2_PORT         := 6383
NODE2_PID_PATH     := ${BUILD_DIR}/redis_node2.pid
NODE2_SOCKET_PATH  := ${BUILD_DIR}/redis_node2.sock


define kill-redis
  (ls $1 2> /dev/null && kill $$(cat $1) && rm -f $1) || true
endef

all:
	make start_all
	make test
	make stop_all

start_all:
	make start
	make start_slave
	make start_node2
	make start_sentinel
	make start_cluster
	make create_cluster

stop_all:
	make stop_sentinel
	make stop_slave
	make stop
	make stop_cluster
	make stop_node2

${TMP}:
	mkdir -p $@

${BINARY}: ${TMP}
	bin/build ${REDIS_BRANCH} $<

test: ${TEST_FILES}
	env SOCKET_PATH=${SOCKET_PATH} \
		bundle exec ruby -v -e 'ARGV.each { |test_file| require test_file }' ${TEST_FILES}

stop:
	$(call kill-redis,${PID_PATH})

start: ${BINARY}
	${BINARY}                     \
		--daemonize  yes            \
		--pidfile    ${PID_PATH}    \
		--port       ${PORT}        \
		--unixsocket ${SOCKET_PATH}

stop_slave:
	$(call kill-redis,${SLAVE_PID_PATH})

start_slave: ${BINARY}
	${BINARY}\
		--daemonize  yes\
		--pidfile    ${SLAVE_PID_PATH}\
		--port       ${SLAVE_PORT}\
		--unixsocket ${SLAVE_SOCKET_PATH}\
		--slaveof    127.0.0.1 ${PORT}

stop_sentinel:
	$(call kill-redis,${SENTINEL_PID_PATHS})
	rm -f ${TMP}/sentinel*.conf || true

start_sentinel: ${BINARY}
	for port in ${SENTINEL_PORTS}; do\
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
	$(call kill-redis,${CLUSTER_PID_PATHS})
	rm -f appendonly.aof || true
	rm -f ${CLUSTER_CONF_PATHS} || true

start_cluster: ${BINARY}
	for port in ${CLUSTER_PORTS}; do                    \
		${BINARY}                                         \
			--daemonize            yes                      \
			--appendonly           yes                      \
			--cluster-enabled      yes                      \
			--cluster-config-file  ${TMP}/nodes$$port.conf  \
			--cluster-node-timeout 5000                     \
			--pidfile              ${TMP}/redis$$port.pid   \
			--port                 $$port                   \
			--unixsocket           ${TMP}/redis$$port.sock; \
	done

create_cluster:
	yes yes | ((bundle exec ruby ${REDIS_TRIB} create --replicas 1 ${CLUSTER_ADDRS}) || \
		(${REDIS_CLIENT} --cluster create ${CLUSTER_ADDRS} --cluster-replicas 1))

stop_node2:
	$(call kill-redis,${NODE2_PID_PATH})

start_node2: ${BINARY}
	${BINARY}\
		--daemonize  yes\
		--pidfile    ${NODE2_PID_PATH}\
		--port       ${NODE2_PORT}\
		--unixsocket ${NODE2_SOCKET_PATH}

clean:
	(test -d ${BUILD_DIR} && cd ${BUILD_DIR}/src && make clean distclean) || true

.PHONY: all test stop start stop_slave start_slave stop_sentinel start_sentinel\
	stop_cluster start_cluster create_cluster stop_node2 start_node2 stop_all start_all clean
