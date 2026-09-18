# frozen_string_literal: true

require 'bundler/gem_tasks'
Bundler::GemHelper.install_tasks(dir: "cluster", name: "redis-clustering")

require 'rake/testtask'
require 'rbconfig'
require 'fileutils'

desc "Build the optional xxh3 extension (off by default; see ext/redis/xxh3/extconf.rb). " \
     "Needed locally to exercise Redis::XXH3 and its tests."
task :compile do
  ext_dir = File.expand_path("ext/redis/xxh3", __dir__)
  lib_dir = File.expand_path("lib/redis/xxh3", __dir__)
  so_name = "xxh3_ext.#{RbConfig::CONFIG['DLEXT']}"

  Dir.chdir(ext_dir) do
    sh "#{RbConfig.ruby} extconf.rb --enable-xxh3"
    sh "make"
  end

  FileUtils.mkdir_p(lib_dir)
  FileUtils.cp(File.join(ext_dir, so_name), File.join(lib_dir, so_name))
end

namespace :test do
  # `modules` (Redis module commands, e.g. RedisJSON) gets its own task; in CI this runs against
  # standalone on Redis >= 8, or a Redis Stack service started with the `modules` compose profile on older Redis.
  groups = %i(redis distributed sentinel modules)
  groups.each do |group|
    Rake::TestTask.new(group) do |t|
      t.libs << "test"
      t.libs << "lib"
      t.test_files = FileList["test/#{group}/**/*_test.rb"]
      t.options = '-v' if ENV['CI'] || ENV['VERBOSE']
    end
  end

  lost_tests = Dir["test/**/*_test.rb"] - groups.map { |g| Dir["test/#{g}/**/*_test.rb"] }.flatten
  unless lost_tests.empty?
    abort "The following test files are in no group:\n#{lost_tests.join("\n")}"
  end

  Rake::TestTask.new(:cluster) do |t|
    t.libs << "cluster/test" << "test"
    t.libs << "cluster/lib" << "lib"
    t.test_files = FileList["cluster/test/**/*_test.rb"]
    t.options = '-v' if ENV['CI'] || ENV['VERBOSE']
  end
end

task test: ["test:redis", "test:distributed", "test:sentinel", "test:modules", "test:cluster"]

task default: :test
