Getting started
Install with:

$ gem install redis
You can connect to Redis by instantiating the Redis class:

require "redis"

redis = Redis.new
This assumes Redis was started with a default configuration, and is listening on localhost, port 6379. If you need to connect to a remote server or a different port, try:

redis = Redis.new(host: "10.0.1.1", port: 6380, db: 15)
You can also specify connection options as a redis:// URL:

redis = Redis.new(url: "redis://:p4ssw0rd@10.0.1.1:6380/15")
The client expects passwords with special chracters to be URL-encoded (i.e. CGI.escape(password)).

By default, the client will try to read the REDIS_URL environment variable and use that as URL to connect to. The above statement is therefore equivalent to setting this environment variable and calling Redis.new without arguments.

To connect to Redis listening on a Unix socket, try:

redis = Redis.new(path: "/tmp/redis.sock")
To connect to a password protected Redis instance, use:

redis = Redis.new(password: "mysecret")
To connect a Redis instance using ACL, use:

redis = Redis.new(username: 'myname', password: 'mysecret')
The Redis class exports methods that are named identical to the commands they execute. The arguments these methods accept are often identical to the arguments specified on the Redis website. For instance, the SET and GET commands can be called like this:

redis.set("mykey", "hello world")
# => "OK"

redis.get("mykey")
# => "hello world"
All commands, their arguments, and return values are documented and available on RubyDoc.info.
