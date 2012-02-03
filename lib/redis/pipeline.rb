class Redis
  class Pipeline
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
      value = Future.new(command)
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

  class FutureNotReady < RuntimeError
    def initialize
      super("Value will be available once the pipeline executes.")
    end
  end

  class Future < BasicObject
    def initialize(command)
      @command = command
    end

    def inspect
      "<Redis::Future #{@command.inspect}>"
    end

    def _set(object)
      @object = object
    end

    def value
      if defined?(@object)
        @object
      else
        ::Kernel.raise FutureNotReady
      end
    end
  end
end
