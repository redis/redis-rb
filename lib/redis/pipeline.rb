class Redis
  unless defined?(::BasicObject)
    class BasicObject
      instance_methods.each { |meth| undef_method(meth) unless meth =~ /\A(__|instance_eval)/ }
    end
  end

  class Pipeline
    attr :futures

    def initialize
      @without_reconnect = false
      @shutdown = false
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
      future = Future.new(command, block)
      @futures << future
      future
    end

    def call_pipeline(pipeline)
      @shutdown = true if pipeline.shutdown?
      @futures.concat(pipeline.futures)
      nil
    end

    def commands
      @futures.map { |f| f._command }
    end

    def without_reconnect(&block)
      @without_reconnect = true
      yield
    end

    def finish(replies)
      futures.each_with_index.map do |future, i|
        future._set(replies[i])
      end
    end

    class Multi < self
      def finish(replies)
        return if replies.last.nil? # The transaction failed because of WATCH.

        if replies.last.size < futures.size - 2
          # Some command wasn't recognized by Redis.
          raise replies.detect { |r| r.kind_of?(::RuntimeError) }
        end

        super(replies.last)
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
  end
end
