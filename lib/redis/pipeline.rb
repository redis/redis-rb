class Redis
  class Pipeline
    attr_accessor :db

    attr :futures

    def initialize
      @with_reconnect = true
      @shutdown = false
      @futures = []
    end

    def with_reconnect?
      @with_reconnect
    end

    def without_reconnect?
      !@with_reconnect
    end

    def shutdown?
      @shutdown
    end

    def call(command, &block)
      # A pipeline that contains a shutdown should not raise ECONNRESET when
      # the connection is gone.
      @shutdown = true if command.first == :shutdown
      future = Future.new(command, block)
      @futures << future
      future
    end

    def call_pipeline(pipeline)
      @shutdown = true if pipeline.shutdown?
      @futures.concat(pipeline.futures)
      @db = pipeline.db
      nil
    end

    def commands
      @futures.map { |f| f._command }
    end

    def with_reconnect(val=true)
      @with_reconnect = false unless val
      yield
    end

    def without_reconnect(&blk)
      with_reconnect(false, &blk)
    end

    def finish(replies, &blk)
      if blk
        futures.each_with_index.map do |future, i|
          future._set(blk.call(replies[i]))
        end
      else
        futures.each_with_index.map do |future, i|
          future._set(replies[i])
        end
      end
    end

    class Multi < self
      def finish(replies)
        exec = replies.last

        return if exec.nil? # The transaction failed because of WATCH.

        # EXEC command failed.
        raise exec if exec.is_a?(CommandError)

        if exec.size < futures.size
          # Some command wasn't recognized by Redis.
          raise replies.detect { |r| r.is_a?(CommandError) }
        end

        super(exec) do |reply|
          # Because an EXEC returns nested replies, hiredis won't be able to
          # convert an error reply to a CommandError instance itself. This is
          # specific to MULTI/EXEC, so we solve this here.
          reply.is_a?(::RuntimeError) ? CommandError.new(reply.message) : reply
        end
      end

      def commands
        [[:multi]] + super + [[:exec]]
      end
    end
  end

  class FutureNotReady < RuntimeError
    def initialize
      super("Value will be available once the pipeline executes.")
    end
  end

  class Future < BasicObject
    FutureNotReady = ::Redis::FutureNotReady.new

    def initialize(command, transformation)
      @command = command
      @transformation = transformation
      @object = FutureNotReady
    end

    def inspect
      "<Redis::Future #{@command.inspect}>"
    end

    def _set(object)
      @object = @transformation ? @transformation.call(object) : object
      value
    end

    def _command
      @command
    end

    def value
      ::Kernel.raise(@object) if @object.kind_of?(::RuntimeError)
      @object
    end

    def is_a?(other)
      self.class.ancestors.include?(other)
    end

    def class
      Future
    end
  end
end
