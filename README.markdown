# redis-rb

A Ruby client library for the [Redis](http://code.google.com/p/redis) key-value storage system.

## Information about Redis

Redis is a key-value store with some interesting features:

1. It's fast.
2. Keys are strings but values are typed. Currently Redis supports strings, lists, sets and hashes. [Atomic operations](http://code.google.com/p/redis/wiki/CommandReference) can be done on all of these types.

See [the Redis homepage](http://code.google.com/p/redis/wiki/README) for more information.

## Contributing

See the build on [RunCodeRun](http://runcoderun.com/rsanheim/redis-rb).

If you would like to submit patches, you'll need the following for your development environment:

1. RSpec

		sudo gem install rspec

2. Redis

		rake redis:install

3. dtach

		rake dtach:install

## Examples

Check the `examples/` directory. You'll need to have an instance of `redis-server` running before running the examples.
