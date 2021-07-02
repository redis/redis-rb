Cluster support
redis-rb supports clustering.

# Nodes can be passed to the client as an array of connection URLs.
nodes = (7000..7005).map { |port| "redis://127.0.0.1:#{port}" }
redis = Redis.new(cluster: nodes)

# You can also specify the options as a Hash. The options are the same as for a single server connection.
(7000..7005).map { |port| { host: '127.0.0.1', port: port } }
You can also specify only a subset of the nodes, and the client will discover the missing ones using the CLUSTER NODES command.

Redis.new(cluster: %w[redis://127.0.0.1:7000])
If you want the connection to be able to read from any replica, you must pass the replica: true. Note that this connection won't be usable to write keys.

Redis.new(cluster: nodes, replica: true)
The calling code is responsible for avoiding cross slot commands.

redis = Redis.new(cluster: %w[redis://127.0.0.1:7000])

redis.mget('key1', 'key2')
#=> Redis::CommandError (CROSSSLOT Keys in request don't hash to the same slot)

redis.mget('{key}1', '{key}2')
#=> [nil, nil]
The client automatically reconnects after a failover occurred, but the caller is responsible for handling errors while it is happening.
The client support permanent node failures, and will reroute requests to promoted slaves.
The client supports MOVED and ASK redirections transparently.
