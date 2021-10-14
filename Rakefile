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
  task :set_socket_path do
    if ENV['SOCKET_PATH'].nil?
      sock_file = Dir.glob("#{__dir__}/**/redis.sock").first

      if sock_file.nil?
        puts '`SOCKET_PATH` environment variable required'
        exit 1
      end

      ENV['SOCKET_PATH'] = sock_file
    end
  end
end

Rake::Task[:test].enhance(["test:set_socket_path"])

task default: :test
