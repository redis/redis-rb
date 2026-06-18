# frozen_string_literal: true

require "./lib/redis/version"

Gem::Specification.new do |s|
  s.name = "redis"

  s.version = Redis::VERSION

  s.homepage = "https://github.com/redis/redis-rb"

  s.summary = "A Ruby client library for Redis"

  s.description = <<-EOS
    A Ruby client that tries to match Redis' API one-to-one, while still
    providing an idiomatic interface.
  EOS

  s.license = "MIT"

  s.authors = [
    "Ezra Zygmuntowicz",
    "Taylor Weibley",
    "Matthew Clark",
    "Brian McKinney",
    "Salvatore Sanfilippo",
    "Luca Guidi",
    "Michel Martens",
    "Damian Janowski",
    "Pieter Noordhuis"
  ]

  s.email = ["redis-db@googlegroups.com"]

  s.metadata = {
    "bug_tracker_uri" => "#{s.homepage}/issues",
    "changelog_uri" => "#{s.homepage}/blob/master/CHANGELOG.md",
    "documentation_uri" => "https://www.rubydoc.info/gems/redis/#{s.version}",
    "homepage_uri" => s.homepage,
    "source_code_uri" => "#{s.homepage}/tree/v#{s.version}"
  }

  s.files = Dir["CHANGELOG.md", "LICENSE", "README.md", "lib/**/*"]

  s.required_ruby_version = '>= 2.6.0'

  # Pinned to a single redis-client minor: redis-rb couples tightly to redis-client internals
  # (subclassing, ensure_connected/call_v overrides, config access, RESP3/HELLO behavior), and
  # redis-client is pre-1.0 where minors may break. `~> 0.30.0` allows only patch upgrades
  # (0.30.x) so bug/security fixes flow automatically; new minors require a deliberate redis-rb bump.
  s.add_runtime_dependency('redis-client', '~> 0.30.0')
end
