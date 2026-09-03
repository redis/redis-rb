# frozen_string_literal: true

class Redis
  module Commands
    module Scripting
      # Control remote script registry.
      #
      # @example Load a script
      #   sha = redis.script(:load, "return 1")
      #     # => <sha of this script>
      # @example Check if a script exists
      #   redis.script(:exists, sha)
      #     # => true
      # @example Check if multiple scripts exist
      #   redis.script(:exists, [sha, other_sha])
      #     # => [true, false]
      # @example Flush the script registry
      #   redis.script(:flush)
      #     # => "OK"
      # @example Kill a running script
      #   redis.script(:kill)
      #     # => "OK"
      #
      # @param [String] subcommand e.g. `exists`, `flush`, `load`, `kill`
      # @param [Array<String>] args depends on subcommand
      # @return [String, Boolean, Array<Boolean>, ...] depends on subcommand
      #
      # @see #eval
      # @see #evalsha
      def script(subcommand, *args)
        subcommand = subcommand.to_s.downcase

        if subcommand == "exists"
          arg = args.first

          send_command([:script, :exists, arg]) do |reply|
            reply = reply.map { |r| Boolify.call(r) }

            if arg.is_a?(Array)
              reply
            else
              reply.first
            end
          end
        else
          send_command([:script, subcommand] + args)
        end
      end

      # Evaluate Lua script.
      #
      # @example EVAL without KEYS nor ARGV
      #   redis.eval("return 1")
      #     # => 1
      # @example EVAL with KEYS and ARGV as array arguments
      #   redis.eval("return { KEYS, ARGV }", ["k1", "k2"], ["a1", "a2"])
      #     # => [["k1", "k2"], ["a1", "a2"]]
      # @example EVAL with KEYS and ARGV in a hash argument
      #   redis.eval("return { KEYS, ARGV }", :keys => ["k1", "k2"], :argv => ["a1", "a2"])
      #     # => [["k1", "k2"], ["a1", "a2"]]
      #
      # @param [Array<String>] keys optional array with keys to pass to the script
      # @param [Array<String>] argv optional array with arguments to pass to the script
      # @param [Hash] options
      #   - `:keys => Array<String>`: optional array with keys to pass to the script
      #   - `:argv => Array<String>`: optional array with arguments to pass to the script
      # @return depends on the script
      #
      # @see #script
      # @see #evalsha
      def eval(*args)
        _eval(:eval, args)
      end

      # Evaluate Lua script by its SHA.
      #
      # @example EVALSHA without KEYS nor ARGV
      #   redis.evalsha(sha)
      #     # => <depends on script>
      # @example EVALSHA with KEYS and ARGV as array arguments
      #   redis.evalsha(sha, ["k1", "k2"], ["a1", "a2"])
      #     # => <depends on script>
      # @example EVALSHA with KEYS and ARGV in a hash argument
      #   redis.evalsha(sha, :keys => ["k1", "k2"], :argv => ["a1", "a2"])
      #     # => <depends on script>
      #
      # @param [Array<String>] keys optional array with keys to pass to the script
      # @param [Array<String>] argv optional array with arguments to pass to the script
      # @param [Hash] options
      #   - `:keys => Array<String>`: optional array with keys to pass to the script
      #   - `:argv => Array<String>`: optional array with arguments to pass to the script
      # @return depends on the script
      #
      # @see #script
      # @see #eval
      def evalsha(*args)
        _eval(:evalsha, args)
      end

      # Manage Redis Functions libraries.
      #
      # @example Load a library
      #   redis.function(:load, "#!lua name=mylib\n...")
      #     # => "mylib"
      # @example Replace an existing library
      #   redis.function(:load, code, replace: true)
      #     # => "mylib"
      # @example List loaded libraries
      #   redis.function(:list)
      #     # => [{ "library_name" => "mylib", "engine" => "LUA", "functions" => [...] }]
      # @example List one library including its source code
      #   redis.function(:list, libraryname: "mylib", withcode: true)
      # @example Delete a library
      #   redis.function(:delete, "mylib")
      #     # => "OK"
      # @example Dump and restore all libraries
      #   payload = redis.function(:dump)
      #   redis.function(:restore, payload, policy: :replace)
      #     # => "OK"
      # @example Get engine and running-function statistics
      #   redis.function(:stats)
      #     # => { "running_script" => nil,
      #     #      "engines" => { "LUA" => { "libraries_count" => 1, "functions_count" => 2 } } }
      # @example Kill the currently running function
      #   redis.function(:kill)
      #     # => "OK"
      #
      # @param [String, Symbol] subcommand e.g. `load`, `delete`, `flush`, `list`, `dump`, `restore`, `stats`, `kill`
      # @param [Array<String>] args depends on subcommand
      # @param [Hash] options
      #   - `:replace => true`: (`load`) overwrite an existing library of the same name
      #   - `:libraryname => String`: (`list`) only list libraries matching this pattern
      #   - `:withcode => true`: (`list`) include each library's source code in the reply
      #   - `:policy => Symbol`: (`restore`) one of `:append` (default), `:flush`, `:replace`
      # @return [String, Array<Hash>, Hash] depends on subcommand
      #
      # @see #fcall
      # @see #fcall_ro
      def function(subcommand, *args, **options)
        subcommand = subcommand.to_s.downcase

        case subcommand
        when "load"
          command = %i[function load]
          command << "REPLACE" if options[:replace]
          send_command(command + args)
        when "list"
          command = %i[function list]
          command << "LIBRARYNAME" << options[:libraryname] if options[:libraryname]
          command << "WITHCODE" if options[:withcode]
          send_command(command, &HashifyFunctionList)
        when "restore"
          command = %i[function restore] + args
          command << options[:policy].to_s.upcase if options[:policy]
          send_command(command)
        when "stats"
          send_command(%i[function stats], &HashifyFunctionStats)
        else
          send_command([:function, subcommand] + args)
        end
      end

      # Invoke a Redis Function loaded with FUNCTION LOAD.
      #
      # @example FCALL without keys nor arguments
      #   redis.fcall("myfunc")
      #     # => <depends on the function>
      # @example FCALL with keys and arguments as array arguments
      #   redis.fcall("myfunc", ["k1", "k2"], ["a1", "a2"])
      #     # => <depends on the function>
      # @example FCALL with keys and arguments in a hash argument
      #   redis.fcall("myfunc", :keys => ["k1", "k2"], :argv => ["a1", "a2"])
      #     # => <depends on the function>
      #
      # @param [Array<String>] keys optional array with keys to pass to the function
      # @param [Array<String>] argv optional array with arguments to pass to the function
      # @param [Hash] options
      #   - `:keys => Array<String>`: optional array with keys to pass to the function
      #   - `:argv => Array<String>`: optional array with arguments to pass to the function
      # @return depends on the function
      #
      # @see #function
      # @see #fcall_ro
      def fcall(*args)
        _eval(:fcall, args)
      end

      # Invoke a read-only Redis Function loaded with FUNCTION LOAD.
      #
      # The function must have been registered with the `no-writes` flag.
      #
      # @example FCALL_RO with a key
      #   redis.fcall_ro("myfunc", ["k1"])
      #     # => <depends on the function>
      #
      # @param [Array<String>] keys optional array with keys to pass to the function
      # @param [Array<String>] argv optional array with arguments to pass to the function
      # @param [Hash] options
      #   - `:keys => Array<String>`: optional array with keys to pass to the function
      #   - `:argv => Array<String>`: optional array with arguments to pass to the function
      # @return depends on the function
      #
      # @see #function
      # @see #fcall
      def fcall_ro(*args)
        _eval(:fcall_ro, args)
      end

      private

      def _eval(cmd, args)
        script = args.shift
        options = args.pop if args.last.is_a?(Hash)
        options ||= {}

        keys = args.shift || options[:keys] || []
        argv = args.shift || options[:argv] || []

        send_command([cmd, script, keys.length] + keys + argv)
      end
    end
  end
end
