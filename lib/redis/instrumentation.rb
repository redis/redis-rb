# frozen_string_literal: true

class Redis
  module Instrumentation
    class ParameterFilter
      FILTERED = "[FILTERED]"

      # Commands where all arguments are always sensitive
      SENSITIVE_COMMANDS = %w[auth].freeze

      # Config keys whose values must be filtered on CONFIG SET
      SENSITIVE_CONFIG_KEYS = %w[requirepass masterauth masteruser].freeze

      # @param patterns [Array<String, Symbol, Regexp>] additional filter patterns.
      #   When nil, auto-loads Rails filter_parameters if available.
      def initialize(patterns: nil)
        @custom_patterns = patterns
        @compiled = nil
      end

      # Returns a filtered copy of args with sensitive data replaced.
      # @param command_name [String] downcased command name
      # @param args [Array] raw command arguments
      # @return [Array] filtered arguments
      def filter_args(command_name, args)
        return args if args.empty?

        if SENSITIVE_COMMANDS.include?(command_name)
          return args.map { FILTERED }
        end

        if command_name == "config"
          filtered = filter_config_args(args)
          return filtered if filtered
        end

        filter_with_patterns(args)
      end

      # Resets compiled patterns so Rails filter_parameters are re-read.
      def reset!
        @compiled = nil
      end

      private

      def compiled_patterns
        @compiled ||= compile_patterns(all_patterns)
      end

      def all_patterns
        if @custom_patterns
          Array(@custom_patterns)
        else
          rails_filter_parameters
        end
      end

      def rails_filter_parameters
        if defined?(::Rails) &&
            ::Rails.respond_to?(:application) &&
            ::Rails.application &&
            ::Rails.application.respond_to?(:config) &&
            ::Rails.application.config.respond_to?(:filter_parameters)
          Array(::Rails.application.config.filter_parameters)
        else
          []
        end
      rescue StandardError
        []
      end

      def compile_patterns(patterns)
        patterns.filter_map do |pattern|
          case pattern
          when Regexp then pattern
          when Symbol, String
            /#{Regexp.escape(pattern.to_s)}/i
          end
        end
      end

      def filter_config_args(args)
        sub = args[0].to_s.downcase
        return nil unless sub == "set" && args.length >= 3

        key = args[1].to_s.downcase
        if SENSITIVE_CONFIG_KEYS.include?(key)
          [args[0], args[1]] + args[2..].map { FILTERED }
        end
      end

      def filter_with_patterns(args)
        return args if compiled_patterns.empty?

        args.map do |arg|
          str = arg.to_s
          if compiled_patterns.any? { |p| p.match?(str) }
            FILTERED
          else
            arg
          end
        end
      end
    end

    class Event
      attr_reader :command_name, :command, :args, :redis_id, :start_time
      attr_accessor :result, :error, :duration

      def initialize(command, redis_id)
        @command = command.frozen? ? command : command.dup.freeze
        @command_name = command[0].to_s.downcase.freeze
        @args = command[1..].freeze
        @redis_id = redis_id
        @start_time = nil
        @result = nil
        @error = nil
        @duration = nil
      end

      def error?
        !@error.nil?
      end

      # Returns args with sensitive data replaced by [FILTERED].
      # Uses the global parameter_filter configured on Instrumentation.
      def filtered_args
        @filtered_args ||= Instrumentation.parameter_filter.filter_args(@command_name, @args)
      end

      private

      attr_writer :start_time
    end

    @mutex = Mutex.new
    @before_hooks = []
    @after_hooks = []
    @around_hooks = []
    @disconnect_hooks = []
    @enabled = false
    @parameter_filter = ParameterFilter.new

    class << self
      # The active parameter filter. Configurable via Instrumentation.parameter_filter=
      attr_reader :parameter_filter

      def enabled?
        @enabled
      end

      # Replace the parameter filter.
      # @param filter [ParameterFilter] a configured filter instance
      def parameter_filter=(filter)
        @parameter_filter = filter
      end

      def before_command(&block)
        @mutex.synchronize do
          @before_hooks << block
          @enabled = true
        end
        block
      end

      def after_command(&block)
        @mutex.synchronize do
          @after_hooks << block
          @enabled = true
        end
        block
      end

      def around_command(&block)
        @mutex.synchronize do
          @around_hooks << block
          @enabled = true
        end
        block
      end

      def after_disconnect(&block)
        @mutex.synchronize do
          @disconnect_hooks << block
          @enabled = true
        end
        block
      end

      def remove_hook(hook)
        @mutex.synchronize do
          @before_hooks.delete(hook)
          @after_hooks.delete(hook)
          @around_hooks.delete(hook)
          @disconnect_hooks.delete(hook)
          @enabled = [@before_hooks, @after_hooks, @around_hooks, @disconnect_hooks].any? { |h| !h.empty? }
        end
      end

      def notify_disconnect(redis_id)
        hooks = @mutex.synchronize { @disconnect_hooks.dup }
        hooks.each do |hook|
          hook.call(redis_id)
        rescue StandardError
          nil
        end
      end

      def clear!
        @mutex.synchronize do
          @before_hooks.clear
          @after_hooks.clear
          @around_hooks.clear
          @disconnect_hooks.clear
          @enabled = false
        end
      end

      def instrument(command, redis_id)
        before, after, around = @mutex.synchronize do
          [@before_hooks.dup, @after_hooks.dup, @around_hooks.dup]
        end

        event = Event.new(command, redis_id)

        before.each do |hook|
          hook.call(event)
        rescue StandardError
          nil
        end

        execute = -> {
          event.send(:start_time=, Process.clock_gettime(Process::CLOCK_MONOTONIC))
          begin
            event.result = yield
          rescue => e
            event.error = e
            raise
          ensure
            event.duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - event.start_time
          end
          event.result
        }

        chain = around.reverse_each.reduce(execute) do |inner, hook|
          -> { hook.call(event, inner) }
        end

        begin
          chain.call
        ensure
          after.each do |hook|
            hook.call(event)
          rescue StandardError
            nil
          end
        end
      end
    end

    module Hooks
      class Logger
        VALID_LEVELS = %i[debug info warn error fatal].freeze

        attr_reader :logger, :level, :filter

        # @param logger [::Logger] any Logger-compatible object
        # @param level [:debug, :info, :warn, :error, :fatal] log level for successful commands
        # @param filter [Proc, nil] optional proc receiving command_name string, return true to log
        # @param log_args [Boolean] whether to include filtered arguments in log output
        def initialize(logger:, level: :debug, filter: nil, log_args: false)
          raise ArgumentError, "Invalid level: #{level}" unless VALID_LEVELS.include?(level)

          @logger = logger
          @level = level
          @filter = filter
          @log_args = log_args
        end

        def to_after_hook
          proc { |event| log_event(event) }
        end

        def install!
          hook = to_after_hook
          Redis::Instrumentation.after_command(&hook)
          hook
        end

        private

        def log_event(event)
          return if @filter && !@filter.call(event.command_name)

          args_str = @log_args ? " #{event.filtered_args.join(' ')}" : ""

          message = if event.error?
            format(
              "Redis %s%s %.2fms ERROR %s (id: %s)",
              event.command_name.upcase,
              args_str,
              event.duration * 1000,
              event.error.class,
              event.redis_id
            )
          else
            format(
              "Redis %s%s %.2fms (id: %s)",
              event.command_name.upcase,
              args_str,
              event.duration * 1000,
              event.redis_id
            )
          end

          @logger.public_send(@level, message)
        end
      end
    end
  end
end
