require 'rubygems'
require 'rake/gempackagetask'
require 'rake/testtask'
require 'tasks/redis.tasks'

$:.unshift File.join(File.dirname(__FILE__), 'lib')
require 'redis'

GEM = 'redis'
GEM_NAME = 'redis'
GEM_VERSION = Redis::VERSION
AUTHORS = ['Ezra Zygmuntowicz', 'Taylor Weibley', 'Matthew Clark', 'Brian McKinney', 'Salvatore Sanfilippo', 'Luca Guidi']
EMAIL = "ez@engineyard.com"
HOMEPAGE = "http://github.com/ezmobius/redis-rb"
SUMMARY = "Ruby client library for Redis, the key value storage server"

spec = Gem::Specification.new do |s|
  s.name = GEM
  s.version = GEM_VERSION
  s.platform = Gem::Platform::RUBY
  s.has_rdoc = true
  s.extra_rdoc_files = ["LICENSE"]
  s.summary = SUMMARY
  s.description = s.summary
  s.authors = AUTHORS
  s.email = EMAIL
  s.homepage = HOMEPAGE
  s.require_path = 'lib'
  s.autorequire = GEM
  s.files = %w(LICENSE README.markdown Rakefile) + Dir.glob("{lib,tasks,spec}/**/*")
end

REDIS_DIR = File.expand_path(File.join("..", "test"), __FILE__)
REDIS_CNF = File.join(REDIS_DIR, "test.conf")
REDIS_PID = File.join(REDIS_DIR, "db", "redis.pid")

task :default => :run

desc "Run tests and manage server start/stop"
task :run => [:start, :test, :stop]

desc "Start the Redis server"
task :start do
  unless File.exists?(REDIS_PID)
    system "redis-server #{REDIS_CNF}"
  end
end

desc "Stop the Redis server"
task :stop do
  if File.exists?(REDIS_PID)
    system "kill #{File.read(REDIS_PID)}"
    system "rm #{REDIS_PID}"
  end
end

Rake::TestTask.new(:test) do |t|
  t.pattern = 'test/**/*_test.rb'
end

Rake::GemPackageTask.new(spec) do |pkg|
  pkg.gem_spec = spec
end

desc "install the gem locally"
task :install => [:package] do
  sh %{sudo gem install pkg/#{GEM}-#{GEM_VERSION}}
end

desc "create a gemspec file"
task :gemspec do
  File.open("#{GEM}.gemspec", "w") do |file|
    file.puts spec.to_ruby
  end
end
