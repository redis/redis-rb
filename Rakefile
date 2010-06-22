require 'rubygems'
require 'rake/gempackagetask'
require 'rake/testtask'

$:.unshift File.join(File.dirname(__FILE__), 'lib')
require 'redis'

GEM = 'redis'
GEM_NAME = 'redis'
GEM_VERSION = Redis::VERSION
AUTHORS = ['Ezra Zygmuntowicz', 'Taylor Weibley', 'Matthew Clark', 'Brian McKinney', 'Salvatore Sanfilippo', 'Luca Guidi', 'Michel Martens', 'Damian Janowski']
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
  redis_running = \
    begin
      File.exists?(REDIS_PID) && Process.kill(0, File.read(REDIS_PID).to_i)
    rescue Errno::ESRCH
      FileUtils.rm REDIS_PID
      false
    end

  system "redis-server #{REDIS_CNF}" unless redis_running
end

desc "Stop the Redis server"
task :stop do
  if File.exists?(REDIS_PID)
    Process.kill "INT", File.read(REDIS_PID).to_i
    FileUtils.rm REDIS_PID
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
  sh %{gem install pkg/#{GEM}-#{GEM_VERSION}}
end

desc "create a gemspec file"
task :gemspec do
  File.open("#{GEM}.gemspec", "w") do |file|
    file.puts spec.to_ruby
  end
end

desc "Generate YARDoc"
task :yardoc do
  require "yard"

  opts = ["--title", "A Ruby client for Redis"]

  YARD::CLI::Yardoc.run(*opts)
end

namespace :commands do
  def redis_commands
    $redis_commands ||= begin
      require "open-uri"
      require "nokogiri"

      doc = Nokogiri::HTML(open("http://code.google.com/p/redis/wiki/CommandReference"))

      commands = {}

      doc.xpath("//ul/li").each do |node|
        node.at_xpath("./a").text.split("/").each do |name|
          if name =~ /^[A-Z]+$/
            commands[name.downcase] = node.at_xpath("./tt").text
          end
        end
      end

      commands
    end
  end

  task :doc do
    source = File.read("lib/redis.rb")

    redis_commands.each do |name, text|
      source.sub!(/(?:^ *#.*\n)*^( *)def #{name}(\(|$)/) do
        indent, extra_args = $1, $2
        comment = "#{indent}# #{text.strip}"

        IO.popen("par p#{2 + indent.size} 80", "r+") do |io|
          io.puts comment
          io.close_write
          comment = io.read
        end

        "#{comment}#{indent}def #{name}#{extra_args}"
      end
    end

    File.open("lib/redis.rb", "w") { |f| f.write(source) }
  end

  task :verify do
    require "redis"

    Dir["test/**/*_test.rb"].each { |f| require "./#{f}" }

    log = StringIO.new

    RedisTest::OPTIONS[:logger] = Logger.new(log)

    redis = Redis.new

    Test::Unit::AutoRunner.run

    report = ["Command", "\033[0mDefined?\033[0m", "\033[0mTested?\033[0m"]

    yes, no = "\033[1;32mYes\033[0m", "\033[1;31mNo\033[0m"

    redis_commands.sort.each do |name, _|
      defined, tested = redis.respond_to?(name), log.string[">> #{name.upcase}"]

      next if defined && tested

      report << name
      report << (defined ? yes : no)
      report << (tested ? yes : no)
    end

    IO.popen("rs 0 3", "w") do |io|
      io.puts report.join("\n")
    end
  end
end
