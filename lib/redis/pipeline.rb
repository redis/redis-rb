class Redis
  class Pipeline
    attr :commands
    attr :futures

    def initialize
      @without_reconnect = false
      @shutdown = false
      @commands = []
      @futures = []
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
      future = Future.new(command, block)
      @futures << future
      future
    end

    def call_pipeline(pipeline, options = {})
      @shutdown = true if pipeline.shutdown?
      @commands.concat(pipeline.commands)
      @futures.concat(pipeline.futures)
      nil
    end

    def without_reconnect(&block)
      @without_reconnect = true
      yield
    end

    def process_replies(replies)
      futures.each_with_index.map do |future, i|
        future._set(replies[i])
      end
    end
  end

  class FutureNotReady < RuntimeError
    def initialize
      super("Value will be available once the pipeline executes.")
    end
  end

  class Future < BasicObject
    NOOP = lambda { |o| o }

    def initialize(command, transformation)
      @command = command
      @transformation = transformation || NOOP
    end

    def inspect
      "<Redis::Future #{@command.inspect}>"
    end

    def _set(object)
      @object = @transformation.call(object)
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
