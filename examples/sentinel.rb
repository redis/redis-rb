require 'redis'
require 'redis/sentinel'

r = Redis::Sentinel.new %w[redis://localhost:26380 redis://localhost:26379], {master_name: 'example-test'}

r.set 'foo', 'bar'
while true
  begin
    puts r.get "foo"
  rescue => e
    puts 'failover took too long to recover', e.backtrace
  end
  sleep 1
end
