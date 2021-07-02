Sentinel support
The client is able to perform automatic failover by using Redis Sentinel. Make sure to run Redis 2.8+ if you want to use this feature.

To connect using Sentinel, use:

SENTINELS = [{ host: "127.0.0.1", port: 26380 },
             { host: "127.0.0.1", port: 26381 }]

redis = Redis.new(url: "redis://mymaster", sentinels: SENTINELS, role: :master)
The master name identifies a group of Redis instances composed of a master and one or more slaves (mymaster in the example).

It is possible to optionally provide a role. The allowed roles are master and slave. When the role is slave, the client will try to connect to a random slave of the specified master. If a role is not specified, the client will connect to the master.

When using the Sentinel support you need to specify a list of sentinels to connect to. The list does not need to enumerate all your Sentinel instances, but a few so that if one is down the client will try the next one. The client is able to remember the last Sentinel that was able to reply correctly and will use it for the next requests.

If you want to authenticate Sentinel itself, you must specify the password option per instance.

SENTINELS = [{ host: '127.0.0.1', port: 26380, password: 'mysecret' },
             { host: '127.0.0.1', port: 26381, password: 'mysecret' }]

redis = Redis.new(host: 'mymaster', sentinels: SENTINELS, role: :master)
