require "rake/testtask"

ENV["REDIS_BRANCH"] ||= "unstable"

REDIS_DIR = File.expand_path(File.join("..", "test"), __FILE__)
REDIS_CNF = File.join(REDIS_DIR, "test.conf")
REDIS_PID = File.join(REDIS_DIR, "db", "redis.pid")
BINARY = "tmp/redis-#{ENV["REDIS_BRANCH"]}/src/redis-server"

task :default => :run

desc "Run tests and manage server start/stop"
task :run => [:start, :test, :stop]

desc "Start the Redis server"
task :start => BINARY do
  sh "#{BINARY} --version"

  redis_running = \
  begin
    File.exists?(REDIS_PID) && Process.kill(0, File.read(REDIS_PID).to_i)
  rescue Errno::ESRCH
    FileUtils.rm REDIS_PID
    false
  end

  unless redis_running
    unless system("#{BINARY} #{REDIS_CNF}")
      abort "could not start redis-server"
    end
  end

  at_exit do
    Rake::Task["stop"].invoke
  end
end

desc "Stop the Redis server"
task :stop do
  if File.exists?(REDIS_PID)
    Process.kill "INT", File.read(REDIS_PID).to_i
    FileUtils.rm REDIS_PID
  end
end

desc "Clean up testing artifacts"
task :clean do
  FileUtils.rm_f(BINARY)
end

file BINARY do
  branch = ENV.fetch("REDIS_BRANCH")

  sh <<-SH
  mkdir -p tmp;
  cd tmp;
  rm -rf redis-#{branch};
  wget https://github.com/antirez/redis/archive/#{branch}.tar.gz -O #{branch}.tar.gz;
  tar xf #{branch}.tar.gz;
  cd redis-#{branch};
  make
  SH
end

Rake::TestTask.new do |t|
  t.options = "-v" if $VERBOSE
  t.test_files = FileList["test/*_test.rb"]
end
