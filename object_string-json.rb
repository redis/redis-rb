require "json"

redis.set "foo", [1, 2, 3].to_json
# => OK

JSON.parse(redis.get("foo"))
# => [1, 2, 3]
