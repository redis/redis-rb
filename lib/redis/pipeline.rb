class Redis
  class Pipeline
    class Value
      def set(object)
        @object = object
      end

      def value
        @object
      end
    end

    attr :commands
    attr :blocks
    attr :values

    def initialize
      @without_reconnect = false
      @shutdown = false
      @commands = []
      @blocks = []
      @values = []
    end

    def without_reconnect?
      @without_reconnect
    end

    def shutdown?
      @shutdown
    end

    def call(command, &block)
      # A pipeline that contains a shutdown should not raise ECONNRESET when
      # the connection is gone.
      @shutdown = true if command.first == :shutdown
      @commands << command
      @blocks << block
      value = Value.new
      @values << value
      value
    end

    def call_pipeline(pipeline, options = {})
      @shutdown = true if pipeline.shutdown?
      @commands.concat(pipeline.commands)
      @blocks.concat(pipeline.blocks)
      @values.concat(pipeline.values)
      nil
    end

    def without_reconnect(&block)
      @without_reconnect = true
      yield
    end
  end
end
