# frozen_string_literal: true

run lambda { |_env|
  [200, { "Content-Type" => "text/plain" }, [MyApp.redis.randomkey]]
}
