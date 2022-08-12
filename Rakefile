# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new :test do |t|
  t.libs = %w(lib test)

  if ARGV.size == 1
    t.pattern = 'test/*_test.rb'
  else
    t.test_files = ARGV[1..-1]
  end

  t.options = '-v' if ENV['CI'] || ENV['VERBOSE']
end

namespace :test do
  groups = %i(redis distributed sentinel cluster)
  groups.each do |group|
    Rake::TestTask.new(group) do |t|
      t.libs << "test"
      t.libs << "lib"
      t.test_files = FileList["test/#{group}/**/*_test.rb"]
    end
  end

  lost_tests = Dir["test/**/*_test.rb"] - groups.map { |g| Dir["test/#{g}/**/*_test.rb"] }.flatten
  unless lost_tests.empty?
    abort "The following test files are in no group:\n#{lost_tests.join("\n")}"
  end
end

task test: ["test:redis", "test:distributed", "test:sentinel", "test:cluster"]

task default: :test
