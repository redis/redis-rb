require 'rubygems'
require 'ruby-prof'
require "#{File.dirname(__FILE__)}/lib/redis"

@r = Redis.new
@r['foo'] = "The first line we sent to the server is some text"

mode = ARGV.shift || 'process_time'
RubyProf.measure_mode = RubyProf.const_get(mode.upcase)
RubyProf.start
100.times do |i|
  @r["foo#{i}"] = "The first line we sent to the server is some text"
  10.times do
    @r["foo#{i}"]
  end
end
results = RubyProf.stop
File.open("profile.#{mode}", 'w') do |out|
  RubyProf::CallTreePrinter.new(results).print(out)
end
