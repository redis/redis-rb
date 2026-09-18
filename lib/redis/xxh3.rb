# frozen_string_literal: true

begin
  require "redis/xxh3/xxh3_ext"
rescue LoadError
  raise LoadError, "Redis::XXH3 requires the redis gem's optional xxh3 extension, which is " \
                    "not built by default. Reinstall with `gem install redis -- --enable-xxh3`, " \
                    "or `bundle config build.redis --enable-xxh3` then `bundle install`."
end

class Redis
  # Local (client-side) XXH3-64 digest computation, matching the Redis server's `DIGEST`
  # command exactly (same reference xxHash source, same `%016x` hex formatting), so a
  # digest computed here and one fetched from the server for the same value are
  # byte-identical. Intended to pair with `SET`'s `:ifdeq`/`:ifdne` options and `DELEX`'s
  # `:ifdeq`/`:ifdne` options without requiring a round trip to compute the digest.
  #
  # Not required by default — this is an optional native extension (see
  # ext/redis/xxh3/extconf.rb) that must be built with `--enable-xxh3`.
  #
  # @example
  #   digest = Redis::XXH3.hexdigest("bar")
  #   redis.set("foo", "bar")
  #   redis.digest("foo") == digest # => true
  module XXH3
    # @param value [String, #to_s] the value to hash
    # @return [String] 16 lowercase hex characters
    def self.hexdigest(value)
      _hexdigest(value.to_s.b)
    end
  end
end
