require File.dirname(__FILE__) + '/spec_helper'

describe "Redis::Server" do
  before(:each) do
    @server = Server.new 'localhost', '6379'
  end

  it "should have a connection pool" do
    @server.instance_variable_get(:@sockets).should_not be_nil
  end

  it "should checkout active connections" do
    threads = []
    100.times do
      threads << Thread.new do
        lambda {
          sleep 6 # redis will close idle connections in the meanwhile
          socket = @server.socket
          socket.write("INFO\r\n")
          socket.read(1)
        }.should_not raise_error(Exception)
      end
    end
  end
end
