# frozen_string_literal: true

require 'bundler/gem_tasks'
Bundler::GemHelper.install_tasks(dir: "redis_cluster", name: "redis_cluster")

require 'rake/testtask'

namespace :test do
  groups = %i(redis distributed sentinel)
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
    t.libs << "redis_cluster/test" << "test"
    t.libs << "redis_cluster/lib" << "lib"
    t.test_files = FileList["redis_cluster/test/**/*_test.rb"]
    t.options = '-v' if ENV['CI'] || ENV['VERBOSE']
  end
end

task test: ["test:redis", "test:distributed", "test:sentinel", "test:cluster"]

task default: :test
