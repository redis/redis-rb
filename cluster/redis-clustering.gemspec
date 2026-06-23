# frozen_string_literal: true

require_relative "../lib/redis/version"

Gem::Specification.new do |s|
  s.name = "redis-clustering"

  s.version = Redis::VERSION

  github_root = "https://github.com/redis/redis-rb"
  s.homepage = "#{github_root}/blob/master/cluster"

  s.summary = "A Ruby client library for Redis Cluster"

  s.description = <<-EOS
  A Ruby client that tries to match Redis' Cluster API one-to-one, while still
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
    "bug_tracker_uri" => "#{github_root}/issues",
    "changelog_uri" => "#{s.homepage}/CHANGELOG.md",
    "documentation_uri" => "https://www.rubydoc.info/gems/redis/#{s.version}",
    "homepage_uri" => s.homepage,
    "source_code_uri" => "#{github_root}/tree/v#{s.version}/cluster"
  }

  s.files         = Dir["CHANGELOG.md", "LICENSE", "README.md", "lib/**/*"]
  s.executables   = `git ls-files -- exe/*`.split("\n").map { |f| File.basename(f) }

  s.required_ruby_version = '>= 3.3.0'

  s.add_runtime_dependency('redis', s.version)
  # Patch-only within the current redis-cluster-client minor (pre-1.0, so minors may break and we
  # rely on its internals — e.g. InitialSetupError). Bug/security patches flow; minors are gated.
  s.add_runtime_dependency('redis-cluster-client', '~> 0.16.0')
end
