# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = %q{redis}
  s.version = "2.1.1"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Ezra Zygmuntowicz", "Taylor Weibley", "Matthew Clark", "Brian McKinney", "Salvatore Sanfilippo", "Luca Guidi", "Michel Martens", "Damian Janowski"]
  s.autorequire = %q{redis}
  s.date = %q{2011-03-22}
  s.description = %q{Ruby client library for Redis, the key value storage server}
  s.email = %q{ez@engineyard.com}
  s.extra_rdoc_files = ["LICENSE"]
  s.files = ["LICENSE", "README.md", "Rakefile", "lib/redis", "lib/redis/client.rb", "lib/redis/compat.rb", "lib/redis/connection", "lib/redis/connection/hiredis.rb", "lib/redis/connection/ruby.rb", "lib/redis/connection.rb", "lib/redis/distributed.rb", "lib/redis/hash_ring.rb", "lib/redis/pipeline.rb", "lib/redis/subscribe.rb", "lib/redis/version.rb", "lib/redis.rb"]
  s.homepage = %q{http://github.com/ezmobius/redis-rb}
  s.require_paths = ["lib"]
  s.rubygems_version = %q{1.5.0}
  s.summary = %q{Ruby client library for Redis, the key value storage server}

  if s.respond_to? :specification_version then
    s.specification_version = 3

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
    else
    end
  else
  end
end
