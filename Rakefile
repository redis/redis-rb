require 'rake/testtask'
Rake::TestTask.new 'test' do |t|
  if ENV['SOCKET_PATH'].nil?
    sock_file = Dir.glob("#{__dir__}/**/redis.sock").first

    if sock_file.nil?
      puts '`SOCKET_PATH` environment variable required'
      exit 1
    end

    ENV['SOCKET_PATH'] = sock_file
  end

  t.libs = %w(lib test)

  if ARGV.size == 1
    t.pattern = 'test/*_test.rb'
  else
    t.test_files = ARGV[1..-1]
  end

  t.options = '-v'
end

task default: :test
