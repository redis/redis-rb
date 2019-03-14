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

  s.files         = Dir["CHANGELOG.md", "LICENSE", "README.md", "lib/**/*"]
  s.executables   = `git ls-files -- exe/*`.split("\n").map{ |f| File.basename(f) }

  s.required_ruby_version = '>= 2.2.2'

  s.add_development_dependency("test-unit", ">= 3.1.5")
  s.add_development_dependency("mocha")
  s.add_development_dependency("hiredis")
  s.add_development_dependency("em-synchrony")
  s.add_development_dependency("async-io")
end
