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

  s.required_ruby_version = '>= 3.3.0'

  # Pinned to an exact redis-client version: redis-rb couples tightly to redis-client internals
  # (subclassing, ensure_connected/call_v overrides, config access, RESP3/HELLO behavior), and
  # the pre-1.0 driver family ships behavior changes in patch releases, so even a `~> x.y.0`
  # constraint can change semantics under a stable redis release. Bump deliberately and re-run
  # the full suite. Note hiredis-client versions in lockstep (it requires redis-client `= x.y.z`).
  s.add_runtime_dependency('redis-client', '0.30.1')
end
