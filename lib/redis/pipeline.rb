class Redis
  class Pipeline
    attr :commands
    attr :blocks

    def initialize
      @without_reconnect = false
      @shutdown = false
      @commands = []
      @blocks = []
    end

    def without_reconnect?
      @without_reconnect
    end

    def shutdown?
      @shutdown
    end

    # Starting with 2.2.1, assume that this method is called with a single
    # array argument. Check its size for backwards compat.
    def call(*args, &block)
      if args.first.is_a?(Array) && args.size == 1
        command = args.first
      else
        command = args
      end

      # A pipeline that contains a shutdown should not raise ECONNRESET when
      # the connection is gone.
      @shutdown = true if command.first == :shutdown
      @commands << command
      @blocks << block
      nil
    end

    def call_pipeline(pipeline, options = {})
      @shutdown = true if pipeline.shutdown?
      @commands.concat(pipeline.commands)
      @blocks.concat(pipeline.blocks)
      nil
    end

    def without_reconnect(&block)
      @without_reconnect = true
      yield
    end
  end
end
