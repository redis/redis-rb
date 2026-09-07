# frozen_string_literal: true

require "redis/commands/arrays"
require "redis/commands/bitmaps"
require "redis/commands/cluster"
require "redis/commands/connection"
require "redis/commands/geo"
require "redis/commands/hashes"
require "redis/commands/hyper_log_log"
require "redis/commands/keys"
require "redis/commands/lists"
require "redis/commands/modules/json"
require "redis/commands/pubsub"
require "redis/commands/scripting"
require "redis/commands/modules/search"
require "redis/commands/server"
require "redis/commands/sets"
require "redis/commands/sorted_sets"
require "redis/commands/streams"
require "redis/commands/strings"
require "redis/commands/transactions"
require "redis/commands/vector_sets"

class Redis
  module Commands
    include Arrays
    include Bitmaps
    include Cluster
    include Connection
    include Geo
    include Hashes
    include HyperLogLog
    include Keys
    include Lists
    include Json
    include Pubsub
    include Scripting
    include Search
    include Server
    include Sets
    include SortedSets
    include Streams
    include Strings
    include Transactions
    include VectorSets

    # Commands returning 1 for true and 0 for false may be executed in a pipeline
    # where the method call will return nil. Propagate the nil instead of falsely
    # returning false.
    Boolify = lambda { |value|
      value != 0 unless value.nil?
    }

    # For commands whose reply is an integer under RESP2 but a native boolean
    # under RESP3 (e.g. VADD): pass booleans through, boolify integers, and
    # propagate nil for pipelined calls.
    BoolifyBoolean = lambda { |value|
      case value
      when true, false, nil
        value
      else
        value != 0
      end
    }

    BoolifySet = lambda { |value|
      case value
      when "OK"
        true
      when nil
        false
      else
        value
      end
    }

    Hashify = lambda { |value|
      if value.is_a?(Hash) # RESP3 already returns a map
        value
      elsif value.respond_to?(:each_slice) # RESP2 flat [k, v, k, v, ...]
        value.each_slice(2).to_h
      else
        value
      end
    }

    Pairify = lambda { |value|
      return value unless value.respond_to?(:each_slice)

      if value.first.is_a?(Array) # RESP3 already returns [[k, v], ...]
        value
      else # RESP2 flat [k, v, k, v, ...]
        value.each_slice(2).to_a
      end
    }

    Floatify = lambda { |value|
      case value
      when "inf"
        Float::INFINITY
      when "-inf"
        -Float::INFINITY
      when String
        Float(value)
      else
        value
      end
    }

    # Number arrays (e.g. the VEMB vector) arrive as native doubles under
    # RESP3 but as bulk strings under RESP2; converge on an array of Floats.
    FloatifyArray = lambda { |value|
      return value unless value.is_a?(Array)

      value.first.is_a?(String) ? value.map(&Floatify) : value
    }

    FloatifyPair = lambda { |(first, score)|
      [first, Floatify.call(score)]
    }

    FloatifyPairs = lambda { |value|
      return value unless value.respond_to?(:each_slice)

      if value.first.is_a?(Array) # RESP3 already returns [[member, score], ...]
        # Scores arrive as native doubles, so the pairs are already in the final shape and
        # re-mapping would only re-allocate identical arrays. Floatify only transforms Strings, so
        # unless a score came back as one (it shouldn't under RESP3) return the parser's array as-is.
        value.first.last.is_a?(String) ? value.map(&FloatifyPair) : value
      else # RESP2 flat [member, score, member, score, ...]
        value.each_slice(2).map(&FloatifyPair)
      end
    }

    # ARINFO: the avg-* slice statistics arrive as native doubles under RESP3
    # but as bulk strings under RESP2; floatify them after hashifying so both
    # protocols return the same Ruby types.
    HashifyArrayInfo = lambda { |value|
      reply = Hashify.call(value)
      return reply unless reply.is_a?(Hash)

      reply.each do |field, field_value|
        reply[field] = Floatify.call(field_value) if field.start_with?("avg-")
      end
    }

    # VEMB RAW: [quantization, blob, l2, (range, q8 only)] with the numeric
    # fields as bulk strings under RESP2 but doubles under RESP3.
    HashifyVectorEmbeddingRaw = lambda { |reply|
      return reply unless reply.is_a?(Array)

      result = {
        "quantization" => reply[0],
        "raw" => reply[1],
        "l2" => Floatify.call(reply[2])
      }
      result["range"] = Floatify.call(reply[3]) if reply.size > 3
      result
    }

    # Element => score pairs (VSIM WITHSCORES, one VLINKS layer): a native map
    # with double scores under RESP3, a flat [name, score, ...] array of bulk
    # strings under RESP2; converge on a Hash of name => Float.
    HashifyVectorScores = lambda { |reply|
      case reply
      when Hash
        reply
      when Array
        reply.each_slice(2).to_h { |name, score| [name, Floatify.call(score)] }
      else
        reply
      end
    }

    # VSIM WITHSCORES WITHATTRIBS: a native map of name => [double, attrs]
    # under RESP3, a flat [name, score, attrs, ...] triplet array under RESP2
    # (attrs is nil for elements without attributes); converge on a Hash of
    # name => [Float, attrs].
    HashifyVectorScoresWithAttribs = lambda { |reply|
      case reply
      when Hash
        reply
      when Array
        reply.each_slice(3).to_h { |name, score, attrs| [name, [Floatify.call(score), attrs]] }
      else
        reply
      end
    }

    # VLINKS WITHSCORES: one name => score map per HNSW layer.
    HashifyVectorLinksWithScores = lambda { |reply|
      return reply unless reply.is_a?(Array)

      reply.map(&HashifyVectorScores)
    }

    HashifyInfo = lambda { |reply|
      lines = reply.split("\r\n").grep_v(/^(#|$)/)
      lines.map! { |line| line.split(':', 2) }
      lines.compact!
      lines.to_h
    }

    HashifyStreams = lambda { |reply|
      case reply
      when nil
        {}
      else
        reply.map { |key, entries| [key, HashifyStreamEntries.call(entries)] }.to_h
      end
    }

    EMPTY_STREAM_RESPONSE = [nil].freeze
    private_constant :EMPTY_STREAM_RESPONSE

    HashifyStreamEntries = lambda { |reply|
      reply.compact.map do |entry_id, values|
        [entry_id, values&.each_slice(2)&.to_h]
      end
    }

    HashifyStreamAutoclaim = lambda { |reply|
      {
        'next' => reply[0],
        'entries' => reply[1].compact.map do |entry, values|
          [entry, values.each_slice(2)&.to_h]
        end
      }
    }

    HashifyStreamAutoclaimJustId = lambda { |reply|
      {
        'next' => reply[0],
        'entries' => reply[1]
      }
    }

    HashifyStreamPendings = lambda { |reply|
      {
        'size' => reply[0],
        'min_entry_id' => reply[1],
        'max_entry_id' => reply[2],
        'consumers' => reply[3].nil? ? {} : reply[3].to_h
      }
    }

    HashifyStreamPendingDetails = lambda { |reply|
      reply.map do |arr|
        {
          'entry_id' => arr[0],
          'consumer' => arr[1],
          'elapsed' => arr[2],
          'count' => arr[3]
        }
      end
    }

    HashifyClusterNodeInfo = lambda { |str|
      arr = str.split(' ')
      # The first slot field can be a range ("0-5460"), a single slot ("5460" —
      # e.g. a scale-out primary's first migrated slot), or, on a node owning no
      # range at all, a bracketed importing/migrating marker; only owned slots
      # reshape into the Range.
      slots = arr[8] unless arr[8].nil? || arr[8].start_with?('[')
      first_slot, last_slot = slots&.split('-')
      {
        'node_id' => arr[0],
        'ip_port' => arr[1],
        'flags' => arr[2].split(','),
        'master_node_id' => arr[3],
        'ping_sent' => arr[4],
        'pong_recv' => arr[5],
        'config_epoch' => arr[6],
        'link_state' => arr[7],
        'slots' => first_slot.nil? ? nil : Range.new(first_slot, last_slot || first_slot)
      }
    }

    HashifyClusterSlots = lambda { |reply|
      reply.map do |arr|
        first_slot, last_slot = arr[0..1]
        master = { 'ip' => arr[2][0], 'port' => arr[2][1], 'node_id' => arr[2][2] }
        replicas = arr[3..-1].map { |r| { 'ip' => r[0], 'port' => r[1], 'node_id' => r[2] } }
        {
          'start_slot' => first_slot,
          'end_slot' => last_slot,
          'master' => master,
          'replicas' => replicas
        }
      end
    }

    HashifyClusterNodes = lambda { |reply|
      reply.split(/[\r\n]+/).map { |str| HashifyClusterNodeInfo.call(str) }
    }

    HashifyClusterSlaves = lambda { |reply|
      reply.map { |str| HashifyClusterNodeInfo.call(str) }
    }

    # FUNCTION LIST: RESP2 replies with a flat [k, v, ...] array per library (and per
    # function within it); RESP3 already returns maps. Converge on nested Hashes.
    HashifyFunctionList = lambda { |reply|
      reply.map do |library|
        library = library.each_slice(2).to_h unless library.is_a?(Hash)
        library["functions"] = library["functions"].map do |function|
          function.is_a?(Hash) ? function : function.each_slice(2).to_h
        end
        library
      end
    }

    # FUNCTION STATS: RESP2 replies with nested flat [k, v, ...] arrays; RESP3 with maps.
    HashifyFunctionStats = lambda { |reply|
      reply = reply.each_slice(2).to_h unless reply.is_a?(Hash)

      running = reply["running_script"]
      reply["running_script"] = running.each_slice(2).to_h if running.is_a?(Array)

      engines = reply["engines"]
      engines = engines.each_slice(2).to_h unless engines.is_a?(Hash)
      reply["engines"] = engines.transform_values do |stats|
        stats.is_a?(Hash) ? stats : stats.each_slice(2).to_h
      end

      reply
    }

    Noop = ->(reply) { reply }

    # Sends a command to Redis and returns its reply.
    #
    # Replies are converted to Ruby objects according to the RESP protocol, so
    # you can expect a Ruby array, integer or nil when Redis sends one. Higher
    # level transformations, such as converting an array of pairs into a Ruby
    # hash, are up to consumers.
    #
    # Redis error replies are raised as Ruby exceptions.
    def call(*command, &block)
      send_command(command, &block)
    end

    # Interact with the sentinel command (masters, master, slaves, failover)
    #
    # @param [String] subcommand e.g. `masters`, `master`, `slaves`
    # @param [Array<String>] args depends on subcommand
    # @return [Array<String>, Hash<String, String>, String] depends on subcommand
    def sentinel(subcommand, *args)
      subcommand = subcommand.to_s.downcase
      send_command([:sentinel, subcommand] + args) do |reply|
        case subcommand
        when "get-master-addr-by-name"
          reply
        else
          case reply
          when Array
            if reply.empty?
              reply # empty list (e.g. sentinels/slaves with no entries) stays []; don't Hashify to {}
            else
              case reply[0]
              when Array then reply.map(&Hashify) # RESP2: list of flat [k, v, ...] arrays
              when Hash then reply                 # RESP3: list of maps (already hashes)
              else Hashify.call(reply)             # RESP2: a single flat [k, v, ...] array
              end
            end
          else
            reply # RESP3 single map, or a scalar reply
          end
        end
      end
    end

    private

    def method_missing(*command) # rubocop:disable Style/MissingRespondToMissing
      send_command(command)
    end
  end
end
