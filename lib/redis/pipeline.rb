class Redis
  class Pipeline
    attr :commands

    def initialize
      @commands = []
    end

    # Starting with 2.2.1, assume that this method is called with a single
    # array argument. Check its size for backwards compat.
    def call(*args)
      if args.first.is_a?(Array) && args.size == 1
        command = args.first
      else
        command = args
      end

      @commands << command
      nil
    end

    def call_pipelined(commands, options = {})
      @commands.concat commands
      nil
    end
  end
end
