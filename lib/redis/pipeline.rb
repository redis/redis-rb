class Redis
  class Pipeline
    attr :commands

    def initialize
      @commands = []
    end

    def call(*args)
      @commands << args
    end
  end
end
