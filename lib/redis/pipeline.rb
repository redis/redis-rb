class Redis
  class Pipeline
    attr :commands

    def initialize
      @commands = []
    end

    def call(*args)
      @commands << args
    end

    def call_pipelined(commands, options = {})
      @commands.concat commands
    end
  end
end
