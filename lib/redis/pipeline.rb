class Redis
  class Pipeline
    attr :commands
    attr :blocks

    def initialize
      @commands = []
      @blocks = []
    end

    # Starting with 2.2.1, assume that this method is called with a single
    # array argument. Check its size for backwards compat.
    def call(*args, &block)
      if args.first.is_a?(Array) && args.size == 1
        command = args.first
      else
        command = args
      end

      @commands << command
      @blocks << block
      nil
    end

    def call_pipeline(pipeline, options = {})
      @commands.concat(pipeline.commands)
      @blocks.concat(pipeline.blocks)
      nil
    end
  end
end
