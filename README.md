# redis-rb [![Build Status][gh-actions-image]][gh-actions-link] [![Inline docs][rdoc-master-image]][rdoc-master-link]

A Ruby client that tries to match [Redis][redis-home]' API one-to-one, while still providing an idiomatic interface.

See [RubyDoc.info][rubydoc] for the API docs of the latest published gem.

## Getting started

Install with:

```
$ gem install redis
```

You can connect to Redis by instantiating the `Redis` class:

```ruby
require "redis"

redis = Redis.new
```

This assumes Redis was started with a default configuration, and is
listening on `localhost`, port 6379. If you need to connect to a remote
server or a different port, try:

```ruby
redis = Redis.new(host: "10.0.1.1", port: 6380, db: 15)
```

You can also specify connection options as a [`redis://` URL][redis-url]:

```ruby
redis = Redis.new(url: "redis://:p4ssw0rd@10.0.1.1:6380/15")
```

The client expects passwords with special characters to be URL-encoded (i.e.
`CGI.escape(password)`).

To connect to Redis listening on a Unix socket, try:

```ruby
redis = Redis.new(path: "/tmp/redis.sock")
```

To connect to a password protected Redis instance, use:

```ruby
redis = Redis.new(password: "mysecret")
```

To connect a Redis instance using [ACL](https://redis.io/topics/acl), use:

```ruby
redis = Redis.new(username: 'myname', password: 'mysecret')
```

The Redis class exports methods that are named identical to the commands
they execute. The arguments these methods accept are often identical to
the arguments specified on the [Redis website][redis-commands]. For
instance, the `SET` and `GET` commands can be called like this:

```ruby
redis.set("mykey", "hello world")
# => "OK"

redis.get("mykey")
# => "hello world"
```

All commands, their arguments, and return values are documented and
available on [RubyDoc.info][rubydoc].

## Language and server support

redis-rb targets actively supported runtimes on both the language and the server side:

- **Ruby:** Ruby 3.2 and newer. See the [Ruby maintenance branches][ruby-branches] page for
  each version's status and dates.
- **Redis server:** the versions designated for support by Redis. See 
[Supported Redis database versions][redis-versions].

## Protocol (RESP3)

Starting in 6.0, the client negotiates the [RESP3 protocol][resp3] (`HELLO 3`)
by default. Command return values are unchanged from 5.x, with one exception:
`GEOPOS` and `GEOSEARCH`/`GEORADIUS` with `WITHCOORD` now return coordinates as
`Float` instead of `String`.

To keep the previous RESP2 behavior, pass `protocol: 2`:

```ruby
redis = Redis.new(protocol: 2)
```

Servers without RESP3 support (Redis < 6.0, or anything replying `NOPROTO`) are
detected on connect and the client transparently falls back to RESP2, so no
configuration is needed for older servers.

### Why RESP3 is the default

RESP3's richer wire types let the parser deliver replies already in their final
Ruby shape. Under RESP2, structured replies arrive as flat arrays of bulk
strings and the client re-shapes them in Ruby: `HGETALL` turns a flat
`[field, value, field, value, ...]` array into a `Hash`, and sorted-set scores
are converted from `String` to `Float` pair by pair. Under RESP3 the server
tags these replies as native maps and doubles, so the final `Hash` and `Float`
values come straight out of the parser and the Ruby-side re-shaping pass
disappears entirely.

How much that saves depends on where parsing happens. In our benchmarks
([bench/resp_comparison.rb](bench/resp_comparison.rb), Ruby 3.4, 100-element
replies), hash reads (`HGETALL`) consistently use ~10–25% less client CPU per
call on both drivers. With the [hiredis driver](#hiredis-binding), where
parsing runs in C, sorted-set reads with scores gain up to 16% throughput and
~20% less CPU per call on top of that; with the pure-Ruby driver they are
unchanged, since the parser then spends in Ruby roughly what the re-shaping
pass used to cost. Simple string commands and stream commands are unaffected
either way — their reply shapes are the same in both protocols. In short:
RESP3 is never slower where it matters, and it pairs best with hiredis — that
combination moves all reply construction out of Ruby and into C.

Beyond performance, RESP3 unlocks protocol capabilities RESP2 simply doesn't
have. The most important is out-of-band **push messages**: the server can send
notifications on a connection without the client asking, which is the
foundation for server-assisted client-side caching (`CLIENT TRACKING`
invalidation events), pub/sub messages delivered over the regular command
connection instead of a dedicated one, and other server-initiated
notifications. Defaulting to RESP3 in 6.0 lays the groundwork for building
these features in future releases without another protocol migration.

See [the RESP3 migration guide](specs/migration-resp3.md) for full details.

## Client identification

On connect the client identifies itself to the server with `CLIENT SETINFO`, so
`redis-rb` and its version are visible in `CLIENT LIST` and `CLIENT INFO`:

```
lib-name=redis-rb lib-ver=<Redis::VERSION>
```

Libraries built on top of `redis-rb` can add their own identity with
`driver_info:`, which is reported alongside it. The recommended suffix format
is `<name>_v<version>`, following the convention used by the official client
libraries:

```ruby
Redis.new(driver_info: "my-gem_v#{MyGem::VERSION}")
# reported as: lib-name=redis-rb(my-gem_v1.0.0) lib-ver=<Redis::VERSION>
```

`driver_info:` also accepts an array, joined with `;` (the conventional
delimiter for multiple suffixes). It extends the reported name rather than
replacing it, so `redis-rb` stays identifiable either way. Runs of characters
the server would reject (spaces, non-printable bytes) and of the parentheses
that delimit the suffix are each replaced with a single `_`, or dropped at the
edges of the value.

Servers older than 7.2 don't support `CLIENT SETINFO`; they reject it, the error
is ignored, and the connection is used as normal. If a proxy or server can't
tolerate the command at all, pass `driver_info: false` to disable client
identification entirely.

## Connection Pooling and Thread safety

The client does not provide connection pooling. Each `Redis` instance
has one and only one connection to the server, and use of this connection
is protected by a mutex.

As such it is heavily recommended to use the [`connection_pool` gem](https://github.com/mperham/connection_pool), e.g.:

```ruby
module MyApp
  def self.redis
    @redis ||= ConnectionPool::Wrapper.new do
      Redis.new(url: ENV["REDIS_URL"])
    end
  end
end

MyApp.redis.incr("some-counter")
```

## Sentinel support

The client is able to perform automatic failover by using [Redis
Sentinel](http://redis.io/topics/sentinel). Make sure to run Redis 2.8+
if you want to use this feature.

To connect using Sentinel, use:

```ruby
SENTINELS = [{ host: "127.0.0.1", port: 26380 },
             { host: "127.0.0.1", port: 26381 }]

redis = Redis.new(name: "mymaster", sentinels: SENTINELS, role: :master)
```

* The master name identifies a group of Redis instances composed of a master
and one or more slaves (`mymaster` in the example).

* It is possible to optionally provide a role. The allowed roles are `master`
and `slave`. When the role is `slave`, the client will try to connect to a
random slave of the specified master. If a role is not specified, the client
will connect to the master.

* When using Sentinel support, you need to specify a list of sentinels to
connect to. The list does not need to enumerate all your Sentinel instances,
but a few so that if one is down the client will try the next one. The client
is able to remember the last Sentinel that was able to reply correctly and will
use it for the next request.

To [authenticate](https://redis.io/docs/management/sentinel/#configuring-sentinel-instances-with-authentication) with Sentinel itself, you can specify the `sentinel_username` and `sentinel_password`. Exclude the `sentinel_username` option if you're using password-only authentication.

```ruby
SENTINELS = [{ host: '127.0.0.1', port: 26380},
             { host: '127.0.0.1', port: 26381}]

redis = Redis.new(name: 'mymaster', sentinels: SENTINELS, sentinel_username: 'appuser', sentinel_password: 'mysecret', role: :master)
```

If you specify a username and/or password at the top level for your main Redis instance, Sentinel *will not* use those credentials.

```ruby
# Use 'mysecret' to authenticate against the mymaster instance, but skip authentication for the sentinels:
SENTINELS = [{ host: '127.0.0.1', port: 26380 },
             { host: '127.0.0.1', port: 26381 }]

redis = Redis.new(name: 'mymaster', sentinels: SENTINELS, role: :master, password: 'mysecret')
```

So you have to provide Sentinel credentials and Redis explicitly even if they are the same.

```ruby
# Use 'mysecret' to authenticate against the mymaster instance and sentinel
SENTINELS = [{ host: '127.0.0.1', port: 26380 },
             { host: '127.0.0.1', port: 26381 }]

redis = Redis.new(name: 'mymaster', sentinels: SENTINELS, role: :master, password: 'mysecret', sentinel_password: 'mysecret')
```

Also, the `name`, `password`, `username`, and `db` for the Redis instance can be passed as a URL:

```ruby
redis = Redis.new(url: "redis://appuser:mysecret@mymaster/10", sentinels: SENTINELS, role: :master)
```

## Cluster support

[Clustering](https://redis.io/topics/cluster-spec). is supported via the [`redis-clustering` gem](cluster/).

## Pipelining

When multiple commands are executed sequentially, but are not dependent,
the calls can be *pipelined*. This means that the client doesn't wait
for reply of the first command before sending the next command. The
advantage is that multiple commands are sent at once, resulting in
faster overall execution.

The client can be instructed to pipeline commands by using the
`#pipelined` method. After the block is executed, the client sends all
commands to Redis and gathers their replies. These replies are returned
by the `#pipelined` method.

```ruby
redis.pipelined do |pipeline|
  pipeline.set "foo", "bar"
  pipeline.incr "baz"
end
# => ["OK", 1]
```

Commands must be called on the yielded objects. If you call methods
on the original client objects from inside a pipeline, they will be sent immediately:

```ruby
redis.pipelined do |pipeline|
  pipeline.set "foo", "bar"
  redis.incr "baz" # => 1
end
# => ["OK"]
```

### Exception management

The `exception` flag in the `#pipelined` is a feature that modifies the pipeline execution behavior. When set
to `false`, it doesn't raise an exception when a command error occurs. Instead, it allows the pipeline to execute all
commands, and any failed command will be available in the returned array. (Defaults to `true`)

```ruby
results = redis.pipelined(exception: false) do |pipeline|
  pipeline.set('key1', 'value1')
  pipeline.lpush('key1', 'something') # This will fail
  pipeline.set('key2', 'value2')
end
# results => ["OK", #<RedisClient::WrongTypeError: WRONGTYPE Operation against a key holding the wrong kind of value>, "OK"]

results.each do |result|
  if result.is_a?(Redis::CommandError)
    # Do something with the failed result
  end
end
```


### Executing commands atomically

You can use `MULTI/EXEC` to run a number of commands in an atomic
fashion. This is similar to executing a pipeline, but the commands are
preceded by a call to `MULTI`, and followed by a call to `EXEC`. Like
the regular pipeline, the replies to the commands are returned by the
`#multi` method.

```ruby
redis.multi do |transaction|
  transaction.set "foo", "bar"
  transaction.incr "baz"
end
# => ["OK", 1]
```

### Futures

Replies to commands in a pipeline can be accessed via the *futures* they
emit. All calls on the pipeline object return a
`Future` object, which responds to the `#value` method. When the
pipeline has successfully executed, all futures are assigned their
respective replies and can be used.

```ruby
set = incr = nil
redis.pipelined do |pipeline|
  set = pipeline.set "foo", "bar"
  incr = pipeline.incr "baz"
end

set.value
# => "OK"

incr.value
# => 1
```

## Bulk hash ingestion (HIMPORT)

> **Experimental:** HIMPORT support is experimental. The client API (method
> signatures, reply aggregation on cluster, and the automatic re-prepare
> behavior) may change in a future minor release without a major version bump.

Redis 8.10 adds the `HIMPORT` command family for loading many hashes that share
the same set of field names: register the field names once with
`himport_prepare`, then create each hash by sending only its values. Keys
written this way are regular hashes — every hash command works on them.

```ruby
redis.himport_prepare("users", ["name", "email", "age"])
redis.himport_set("user:1", "users", ["alice", "alice@example.com", "25"])
redis.himport_set("user:2", "users", ["bob", "bob@example.com", "30"])
redis.himport_discard("users") # => 1
```

Values pair positionally with the prepared fields. Note that hash enumeration
order (`HGETALL`, `HKEYS`) is not guaranteed to match the prepare order.

### Fieldsets are connection state

A prepared fieldset lives in the server-side session of the physical connection
that prepared it: it is invisible to other connections and destroyed by a
disconnect or `RESET`. A `himport_set` on a connection without the fieldset
fails with `ERR no such fieldset`.

Because a `Redis` instance transparently replaces a dead connection (see
[Reconnections](#reconnections)), the client keeps all fieldset schemas
and, when a `himport_set` reports the fieldset is gone, re-prepares it 
and retries the command once. Explicitly discarded fieldsets are never 
restored. To keep the fieldset lifecycle fully explicit instead, disable
the recovery:

```ruby
redis = Redis.new(himport_auto_prepare: false)
```

For the highest ingestion throughput, send the `PREPARE` and its `SET`s as one
pipeline — a single batch always executes on a single connection:

```ruby
redis.pipelined do |pipeline|
  pipeline.himport_prepare("users", ["name", "email", "age"])
  rows.each { |id, row| pipeline.himport_set("user:#{id}", "users", row) }
end
```

If the `PREPARE` in a batch fails, every `SET` in it fails with
`no such fieldset` — the `PREPARE` error is the root cause. Note that the
automatic re-prepare applies to direct calls only, not to commands inside
`pipelined`/`multi` blocks.

When using the `connection_pool` gem, each checkout may hand you a different
underlying connection: run `himport_prepare` and its `himport_set` calls within
one checkout (`pool.with { |redis| ... }`), ideally as one pipelined block.

With `Redis::Distributed`, `himport_prepare`, `himport_discard` and
`himport_discard_all` fan out to every ring node and return an array with one
reply per node; `himport_set` routes by key. With `Redis::Cluster`, the same
commands fan out to every master node and return a single aggregated reply,
matching the standalone API.

## Keyspace Notifications

Redis can publish an event on pub/sub for every change to the dataset
(`__keyspace@0__:<key>` / `__keyevent@0__:<event>` channels; Redis 8.8 adds
subkey-level channels for hash fields). The feature must be enabled on the
**server** via the `notify-keyspace-events` config — this gem deliberately does
not set it for you (`CONFIG` is often restricted, and runtime changes don't
survive restarts or reach new nodes):

```
redis-cli config set notify-keyspace-events KEA      # or KEASTIV for Redis 8.8 subkey events
```

The simplest way to consume notifications is the manager, which owns a
dedicated connection and background thread and dispatches typed notifications
to handlers:

```ruby
manager = redis.keyspace_notifications

manager.subscribe_keyevent("expired") { |n| cache.delete(n.key) }
manager.subscribe_keyspace("user:*")  { |n| puts "#{n.event} on #{n.key}" }
manager.subscribe_subkeyspace("session:*") { |n| p n.subkeys } # Redis 8.8+
manager.on_reconnect { cache.clear } # delivery is fire-and-forget; reconcile after gaps

manager.close
```

Channel builders (`Redis::KeyspaceNotifications::Channels`) and a binary-safe
parser (`Redis::KeyspaceNotifications::Parser.parse(channel, payload)`) are
also usable directly with the plain `subscribe`/`psubscribe` API.

### Subkey notifications (Redis 8.8+)

Classic notifications only say *which key* changed. Redis 8.8 adds four subkey
channel families that also carry *which elements inside the value* changed —
hash fields today, with the model designed to extend to other types. Parsed
notifications expose them as `subkeys`: an ordered list (duplicates preserved)
whose meaning is determined by the event (`hset` → hash fields):

```ruby
manager.subscribe_subkeyspace("session:*") do |n|
  # HSET session:1 token abc ttl 30  =>  event="hset", key="session:1", subkeys=["token", "ttl"]
  n.subkeys.each { |field| invalidate(n.key, field) }
end

# Watch one exact key + field pair (server-side filtering):
manager.subscribe_subkeyspaceitem("session:1", "token") { |n| p n.event }

# Or by event, with a key pattern:
manager.subscribe_subkeyspaceevent("hexpire", "session:*") { |n| p n.subkeys }
```

Subkey families are gated by their own `notify-keyspace-events` flags — `S`
(subkeyspace), `T` (subkeyevent), `I` (subkeyspaceitem), `V` (subkeyspaceevent) —
**and additionally require the data-type flag**: `STIV` alone emits nothing for
hashes; use `STIVh`, or `KEASTIV` to combine with the classic channels. Keys and
subkeys may contain arbitrary bytes, so the wire payloads are length-prefixed
and the parser is binary-safe — `key`/`subkeys` are returned as BINARY-encoded
strings.

**Connection pooling:** create **one manager per process**, not per pooled
connection — pub/sub is a broadcast, so N managers means every event is
delivered and handled N times, not load-shared. The manager is not a pooled
resource: it owns a private connection duplicated from the client's options, so
`pool.with { |redis| redis.keyspace_notifications }` is safe (nothing of the
checked-out client is retained) and the manager outlives the checkout. Handlers
may briefly check pool connections out for Redis work; in forking servers
(Puma, Sidekiq), create the manager in an after-fork hook, one per worker. See
`examples/keyspace_notifications_pool.rb`.

**Cluster:** notifications are node-local — a plain `subscribe` on a
`Redis::Cluster` reaches one node and silently misses the rest. Use
`cluster.keyspace_notifications`, which subscribes on every primary and
reconciles reactively on connection errors (call `#refresh` after adding
primaries). Remember to enable `notify-keyspace-events` on **every node,
replicas included** — a promoted replica keeps its own config.

Never `PUBLISH` to notification channels yourself; the server owns them.
See [specs/keyspace-notifications/user-guide.md](specs/keyspace-notifications/user-guide.md)
for wire formats, threading/lifecycle semantics and the full API, and
`examples/keyspace_notifications.rb` for a runnable demo. `Redis::Distributed`
is not supported.

## Error Handling

In general, if something goes wrong you'll get an exception. For example, if
it can't connect to the server a `Redis::CannotConnectError` error will be raised.

```ruby
begin
  redis.ping
rescue Redis::BaseError => e
  e.inspect
# => #<Redis::CannotConnectError: Timed out connecting to Redis on 10.0.1.1:6380>

  e.message
# => Timed out connecting to Redis on 10.0.1.1:6380
end
```

See lib/redis/errors.rb for information about what exceptions are possible.

## Timeouts

The client allows you to configure connect, read, and write timeouts.
Starting in version 5.0, the default for each is 1. Before that, it was 5.
Passing a single `timeout` option will set all three values:

```ruby
Redis.new(:timeout => 1)
```

But you can use specific values for each of them:

```ruby
Redis.new(
  :connect_timeout => 0.2,
  :read_timeout    => 1.0,
  :write_timeout   => 0.5
)
```

All timeout values are specified in seconds.

When using pub/sub, you can subscribe to a channel using a timeout as well:

```ruby
redis = Redis.new(reconnect_attempts: 0)
redis.subscribe_with_timeout(5, "news") do |on|
  on.message do |channel, message|
    # ...
  end
end
```

If no message is received after 5 seconds, the client will unsubscribe.

## Reconnections

**By default**, this gem will only **retry a connection once** and then fail, but
the client allows you to configure how many `reconnect_attempts` it should
complete before declaring a connection as failed.

```ruby
Redis.new(reconnect_attempts: 0)
Redis.new(reconnect_attempts: 3)
```

If you wish to wait between reconnection attempts, you can instead pass a list
of durations:

```ruby
Redis.new(reconnect_attempts: [
  0, # retry immediately
  0.25, # retry a second time after 250ms
  1, # retry a third and final time after another 1s
])
```

If you wish to disable reconnection only for some commands, you can use
`disable_reconnection`:

```ruby
redis.get("some-key") # this may be retried
redis.disable_reconnection do
  redis.incr("some-counter") # this won't be retried.
end
```

## SSL/TLS Support

To enable SSL support, pass the `:ssl => true` option when configuring the
Redis client, or pass in `:url => "rediss://..."` (like HTTPS for Redis).
You will also need to pass in an `:ssl_params => { ... }` hash used to
configure the `OpenSSL::SSL::SSLContext` object used for the connection:

```ruby
redis = Redis.new(
  :url        => "rediss://:p4ssw0rd@10.0.1.1:6381/15",
  :ssl_params => {
    :ca_file => "/path/to/ca.crt"
  }
)
```

The options given to `:ssl_params` are passed directly to the
`OpenSSL::SSL::SSLContext#set_params` method and can be any valid attribute
of the SSL context. Please see the [OpenSSL::SSL::SSLContext documentation]
for all of the available attributes.

Here is an example of passing in params that can be used for SSL client
certificate authentication (a.k.a. mutual TLS):

```ruby
redis = Redis.new(
  :url        => "rediss://:p4ssw0rd@10.0.1.1:6381/15",
  :ssl_params => {
    :ca_file => "/path/to/ca.crt",
    :cert    => OpenSSL::X509::Certificate.new(File.read("client.crt")),
    :key     => OpenSSL::PKey::RSA.new(File.read("client.key"))
  }
)
```

[OpenSSL::SSL::SSLContext documentation]: http://ruby-doc.org/stdlib-2.5.0/libdoc/openssl/rdoc/OpenSSL/SSL/SSLContext.html

## Expert-Mode Options

 - `inherit_socket: true`: disable safety check that prevents a forked child
   from sharing a socket with its parent; this is potentially useful in order to mitigate connection churn when:
    - many short-lived forked children of one process need to talk
      to redis, AND
    - your own code prevents the parent process from using the redis
      connection while a child is alive

   Improper use of `inherit_socket` will result in corrupted and/or incorrect
   responses.

## hiredis binding

By default, redis-rb uses Ruby's socket library to talk with Redis.

The hiredis driver uses the connection facility of hiredis-rb. In turn,
hiredis-rb is a binding to the official hiredis client library. It
optimizes for speed, at the cost of portability. Because it is a C
extension, JRuby is not supported (by default).

It is best to use hiredis when you have large replies (for example:
`LRANGE`, `SMEMBERS`, `ZRANGE`, etc.) and/or use big pipelines.

In your Gemfile, include `hiredis-client`:

```ruby
gem "redis"
gem "hiredis-client"
```

If your application doesn't call `Bundler.require`, you may have
to require it explicitly:

```ruby
require "hiredis-client"
````

This makes the hiredis driver the default.

If you want to be certain hiredis is being used, when instantiating
the client object, specify hiredis:

```ruby
redis = Redis.new(driver: :hiredis)
```

## See Also

- [async-redis](https://github.com/socketry/async-redis) — An [async](https://github.com/socketry/async) compatible Redis client.

## Contributors

Several people contributed to redis-rb, but we would like to especially
mention Ezra Zygmuntowicz. Ezra introduced the Ruby community to many
new cool technologies, like Redis. He wrote the first version of this
client and evangelized Redis in Rubyland. Thank you, Ezra.

## Contributing

[Fork the project](https://github.com/redis/redis-rb) and send pull
requests.


[rdoc-master-image]: https://img.shields.io/badge/docs-rdoc.info-blue.svg
[rdoc-master-link]:  https://rubydoc.info/github/redis/redis-rb
[redis-commands]:    https://redis.io/commands
[redis-home]:        https://redis.io
[redis-url]:         https://www.iana.org/assignments/uri-schemes/prov/redis
[gh-actions-image]:  https://github.com/redis/redis-rb/workflows/Test/badge.svg
[gh-actions-link]:   https://github.com/redis/redis-rb/actions
[rubydoc]:           https://rubydoc.info/gems/redis
[resp3]:             https://github.com/redis/redis-specifications/blob/master/protocol/RESP3.md
[ruby-branches]:     https://www.ruby-lang.org/en/downloads/branches/
[redis-versions]:    https://redis.io/docs/latest/operate/rc/databases/version-management/#supported-database-versions
