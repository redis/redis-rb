$:.unshift File.expand_path('../lib', File.dirname(__FILE__))

require "cutest"
require "logger"
require "stringio"

begin
  require "ruby-debug"
rescue LoadError
end

PORT    = 6379
OPTIONS = {:port => PORT, :db => 15, :timeout => 3}
NODES   = ["redis://127.0.0.1:6379/15"]

def init(redis)
  begin
    redis.flushdb
    redis.select 14
    redis.flushdb
    redis.select 15
    redis
  rescue Errno::ECONNREFUSED
    puts <<-EOS

      Cannot connect to Redis.

      Make sure Redis is running on localhost, port 6379.
      This testing suite connects to the database 15.

      To install redis:
        visit <http://code.google.com/p/redis/>.

      To start the server:
        rake start

      To stop the server:
        rake stop

    EOS
    exit 1
  end
end

$VERBOSE = true

require "redis"

# Check if hiredis was loaded when tests should be run against it
if ENV["HIREDIS"] == "1"
  ancestors = Redis::Connection.ancestors.map(&:to_s)
  unless ancestors.include?("Hiredis::Ext::Connection")
    flunk("hiredis was not loaded")
  end
end

def capture_stderr
  stderr = $stderr
  $stderr = StringIO.new

  yield

  $stderr = stderr
end

def silent
  verbose, $VERBOSE = $VERBOSE, false

  begin
    yield
  ensure
    $VERBOSE = verbose
  end
end

def with_external_encoding(encoding)
  original_encoding = Encoding.default_external

  begin
    silent { Encoding.default_external = Encoding.find(encoding) }
    yield
  ensure
    silent { Encoding.default_external = original_encoding }
  end
end

def assert_nothing_raised(*exceptions)
  begin
    yield
  rescue *exceptions
    flunk(caller[1])
  end
end

