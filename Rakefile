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
SUMMARY = "Ruby client library for redis key value storage server"

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
  s.add_development_dependency "rspec"
  s.require_path = 'lib'
  s.autorequire = GEM
  s.files = %w(LICENSE README.markdown Rakefile) + Dir.glob("{lib,tasks,spec}/**/*")
end

task :default => :test

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
