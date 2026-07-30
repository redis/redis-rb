# frozen_string_literal: true

require "redis-client"
require "redis/version"

class Redis
  # Reports `redis-rb` as the connecting library via `CLIENT SETINFO`.
  #
  # `redis-client` builds its own `LIB-NAME` as `redis-client(<driver_info>)` and always
  # reports its own version as `LIB-VER`, which would identify `redis-client` rather than
  # `redis-rb` to the server. We append a second pair of `CLIENT SETINFO` commands, which wins
  # because the command is last-write-wins, so that `CLIENT LIST` / `CLIENT INFO` report
  # `lib-name=redis-rb` and `lib-ver=<Redis::VERSION>`.
  #
  # Libraries built on top of `redis-rb` can still identify themselves by passing `driver_info`,
  # in which case they are reported inside the parentheses, e.g. `lib-name=redis-rb(my-gem_v1.0.0)`.
  # The official convention for such suffixes is `<name>_v<version>` (matching
  # `(?<custom-name>[ -~]+)[ -~]v(?<custom-version>[\d\.]+)`), with `;` delimiting multiple
  # suffixes and parentheses avoided inside them — see
  # https://redis.io/docs/latest/commands/client-setinfo/. Passing `driver_info: false` disables
  # `CLIENT SETINFO` entirely, for peers that can't tolerate unknown commands during the handshake
  # (e.g. some proxies).
  #
  # Applications that use `redis-client` directly are left untouched: the override only applies
  # to configurations whose `driver_info` was built by this module.
  module LibIdentity
    # Follows the official suffix convention, so that the transient pair `redis-client` itself
    # builds from this value (`lib-name=redis-client(redis-rb_v<version>)`) is well-formed too.
    MARKER = "redis-rb_v"
    LIB_NAME = "redis-rb"
    SEPARATOR = ";"
    # Interpolated strings are not frozen by the magic comment; explicit freezes keep these
    # constants Ractor-shareable (lazy module ivars here would raise Ractor::IsolationError).
    OWN_INFO = "#{MARKER}#{Redis::VERSION}".freeze
    OWN_PREFIX = "#{OWN_INFO}#{SEPARATOR}".freeze
    # `CLIENT SETINFO` values must be printable ASCII with no spaces — the server rejects anything
    # else, and `redis-client` swallows that error, which would silently leave `lib-name` empty.
    # Parentheses are excluded as well: they delimit the suffix in `lib-name=redis-rb(<suffix>)`,
    # so a suffix containing them would corrupt the reported name.
    INVALID_CHARS = /(?:[^!-~]|[()])+/

    class << self
      # Combines redis-rb's own identity with the `driver_info` a downstream library passed in,
      # so that both can be recovered when the connection prelude is built. `false` is passed
      # through untouched and, being falsy, turns `CLIENT SETINFO` off wholesale (`redis-client`
      # gates its own commands on `driver_info` too). Any other non-String, non-Array value is
      # also passed through, leaving `redis-client` to reject it.
      def driver_info(downstream = nil)
        case downstream
        when nil then OWN_INFO
        when String then combine(downstream)
        when Array then combine(downstream.join(SEPARATOR))
        else downstream
        end
      end

      # True only for values `driver_info` produced: exactly our own identity, or our identity
      # followed by a downstream library's. Matching on the bare `MARKER` prefix instead would
      # also capture a direct `redis-client` user whose own `driver_info` merely starts with
      # `redis-rb_v` (say `redis-rb_viewer-1.0`) and would silently discard their identity.
      def ours?(info)
        info.is_a?(String) && (info == OWN_INFO || info.start_with?(OWN_PREFIX))
      end

      def setinfo_commands(info)
        [
          ["CLIENT", "SETINFO", "LIB-NAME", lib_name(info)].freeze,
          ["CLIENT", "SETINFO", "LIB-VER", Redis::VERSION].freeze,
        ].freeze
      end

      private

      def combine(downstream)
        downstream = downstream.scrub(" ") # invalid byte sequences would make gsub raise
                               .gsub(/\A#{INVALID_CHARS}|#{INVALID_CHARS}\z/o, "")
                               .gsub(INVALID_CHARS, "_")
        downstream.empty? ? OWN_INFO : "#{OWN_PREFIX}#{downstream}"
      end

      def lib_name(info)
        downstream = info == OWN_INFO ? nil : info.delete_prefix(OWN_PREFIX)
        downstream.nil? || downstream.empty? ? LIB_NAME : "#{LIB_NAME}(#{downstream})".freeze
      end
    end

    def connection_prelude
      prelude = super
      info = driver_info
      return prelude unless LibIdentity.ours?(info)

      # `CLIENT SETINFO` is last-write-wins, so appending after the commands `redis-client`
      # already built overrides them, without having to recognise or remove them.
      (prelude + LibIdentity.setinfo_commands(info)).freeze
    end
  end
end

# Prepended to the concrete config classes rather than to `RedisClient::Config::Common`, so that
# the two `redis-client` entry points are covered without altering the shared module for anything
# else that includes it. `RedisClient::SentinelConfig` is NOT a `RedisClient::Config` subclass, so
# both lines are required. `RedisClient::Cluster::Node::Config` does subclass `RedisClient::Config`
# and calls `super` in its own `connection_prelude`, so cluster nodes are covered by the first.
RedisClient::Config.prepend(Redis::LibIdentity)
RedisClient::SentinelConfig.prepend(Redis::LibIdentity)
