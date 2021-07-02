hiredis
The hiredis driver uses the connection facility of hiredis-rb. In turn, hiredis-rb is a binding to the official hiredis client library. It optimizes for speed, at the cost of portability. Because it is a C extension, JRuby is not supported (by default).

It is best to use hiredis when you have large replies (for example: LRANGE, SMEMBERS, ZRANGE, etc.) and/or use big pipelines.

In your Gemfile, include hiredis:

gem "redis", "~> 3.0.1"
gem "hiredis", "~> 0.4.5"
When instantiating the client object, specify hiredis:

redis = Redis.new(:driver => :hiredis)
