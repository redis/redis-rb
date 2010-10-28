# redis-rb

A Ruby client library for the [Redis](http://code.google.com/p/redis) key-value store.

## A note about versions

Versions *1.0.x* target all versions of Redis. You have to use this one if you are using Redis < 1.2.

Version *2.0* is a big refactoring of the previous version and makes little effort to be
backwards-compatible when it shouldn't. It does not support Redis' original protocol, favoring the
new, binary-safe one. You should be using this version if you're running Redis 1.2+.

## Information about Redis

Redis is a key-value store with some interesting features:

1. It's fast.
2. Keys are strings but values are typed. Currently Redis supports strings, lists, sets, sorted sets and hashes. [Atomic operations](http://code.google.com/p/redis/wiki/CommandReference) can be done on all of these types.

See [the Redis homepage](http://code.google.com/p/redis/wiki/README) for more information.

## Getting started

You can connect to Redis by instantiating the `Redis` class:

    require "redis"

    redis = Redis.new

This assumes Redis was started with default values listening on `localhost`, port 6379. If you need to connect to a remote server or a different port, try:

    redis = Redis.new(:host => "10.0.1.1", :port => 6380)

Once connected, you can start running commands against Redis:

    >> redis.set "foo", "bar"
    => "OK"

    >> redis.get "foo"
    => "bar"

    >> redis.sadd "users", "albert"
    => true

    >> redis.sadd "users", "bernard"
    => true

    >> redis.sadd "users", "charles"
    => true

How many users?

    >> redis.scard "users"
    => 3

Is `albert` a user?

    >> redis.sismember "users", "albert"
    => true

Is `isabel` a user?

    >> redis.sismember "users", "isabel"
    => false

Handle groups:

    >> redis.sadd "admins", "albert"
    => true

    >> redis.sadd "admins", "isabel"
    => true

Users who are also admins:

    >> redis.sinter "users", "admins"
    => ["albert"]

Users who are not admins:

    >> redis.sdiff "users", "admins"
    => ["bernard", "charles"]

Admins who are not users:

    >> redis.sdiff "admins", "users"
    => ["isabel"]

All users and admins:

    >> redis.sunion "admins", "users"
    => ["albert", "bernard", "charles", "isabel"]


## Storing objects

Redis only stores strings as values. If you want to store an object inside a key, you can use a serialization/deseralization mechanism like JSON:

    >> redis.set "foo", [1, 2, 3].to_json
    => OK

    >> JSON.parse(redis.get("foo"))
    => [1, 2, 3]

## Executing multiple commands atomically

You can use `MULTI/EXEC` to run arbitrary commands in an atomic fashion:

    redis.multi do
      redis.set "foo", "bar"
      redis.incr "baz"
    end

## Multithreaded Operation

To use redis safely in a multithreaded environment, be sure to initialize the client with :thread_safe=>true

    Redis.new(:thread_safe=>true)

See the tests and benchmarks for examples.


## More info

Check the [Redis Command Reference](http://code.google.com/p/redis/wiki/CommandReference) or check the tests to find out how to use this client.

## Contributing

[Fork the project](http://github.com/ezmobius/redis-rb) and send pull requests. You can also ask for help at `#redis-rb` on Freenode.
