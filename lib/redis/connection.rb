begin
  # Use hiredis when it is available. Explicitly check its version because
  # 0.3.0 is API compliant with redis-rb 2.2.
  require "hiredis/ext/connection"

  major, minor, patch = Hiredis::VERSION.split(".")
  if major.to_i != 0 || minor.to_i != 3
    warn "WARNING: redis-rb #{Redis::VERSION} can use hiredis ~> 0.3.0 (found: #{Hiredis::VERSION}), skipping hiredis."
    raise LoadError
  end

  require "redis/connection/hiredis"
rescue LoadError
  require "redis/connection/pure"
end
