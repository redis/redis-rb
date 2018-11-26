# frozen_string_literal: true

require 'rake/testtask'

task default: :test

desc 'execute test of all or specific files'
Rake::TestTask.new :test do |t|
  # For a test of connecting to Unix domain socket
  if ENV['SOCKET_PATH'].nil?
    sock_file = Dir.glob("#{__dir__}/**/redis.sock").first

    if sock_file.nil?
      puts '`SOCKET_PATH` environment variable required'
      exit 1
    end

    ENV['SOCKET_PATH'] = sock_file
    puts "SOCKET_PATH=#{sock_file}"
  end

  if ARGV.size == 1
    t.pattern = 'test/*_test.rb'
  else
    t.test_files = ARGV[1..-1]
  end

  t.ruby_opts = %w[-v]
  t.options = '-v'
  t.verbose = true
  t.warning = true
end
