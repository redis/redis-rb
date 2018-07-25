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

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }

  s.required_ruby_version = '>= 2.2.2'

  s.add_development_dependency("test-unit", ">= 3.1.5")
  s.add_development_dependency("hiredis")
  s.add_development_dependency("em-synchrony")
  s.add_development_dependency("circuit_breaker")
  s.add_development_dependency("prometheus-client")
end
