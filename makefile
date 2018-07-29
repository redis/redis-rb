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
CLUSTER_PORTS      := 7000 7001 7002 7003 7004 7005
CLUSTER_PID_PATHS  := $(addprefix ${TMP}/redis,$(addsuffix .pid,${CLUSTER_PORTS}))
CLUSTER_CONF_PATHS := $(addprefix ${TMP}/nodes,$(addsuffix .conf,${CLUSTER_PORTS}))
CLUSTER_ADDRS      := $(addprefix 127.0.0.1:,${CLUSTER_PORTS})

define kill-redis
  (ls $1 2> /dev/null && kill $$(cat $1) && rm -f $1) || true
endef

all:
	make start
	make start_cluster
	make create_cluster
	make test
	make stop
	make stop_cluster

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

clean:
	(test -d ${BUILD_DIR} && cd ${BUILD_DIR}/src && make clean distclean) || true

.PHONY: all test stop start stop_cluster start_cluster create_cluster clean
