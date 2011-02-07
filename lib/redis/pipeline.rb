class Redis
  class Pipeline
    attr :commands

    def initialize
      @commands = []
    end

    def call(*args)
      @commands << args
      nil
    end

    def call_pipelined(commands, options = {})
      @commands.concat commands
      nil
    end
  end
end
