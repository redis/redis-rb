require 'monitor'
##
# This class represents a redis server instance.

class Server

  ##
  # The amount of time to wait before attempting to re-establish a
  # connection with a server that is marked dead.

  RETRY_DELAY = 30.0

  ##
  # The host the redis server is running on.

  attr_reader :host

  ##
  # The port the redis server is listening on.

  attr_reader :port
  
  ##
  #
  
  attr_reader :replica

  ##
  # The time of next retry if the connection is dead.

  attr_reader :retry

  ##
  # A text status string describing the state of the server.

  attr_reader :status

  ##
  # Create a new Redis::Server object for the redis instance
  # listening on the given host and port.

  def initialize(host, port = DEFAULT_PORT, timeout = 10, size = 5)
    raise ArgumentError, "No host specified" if host.nil? or host.empty?
    raise ArgumentError, "No port specified" if port.nil? or port.to_i.zero?

    @host   = host
    @port   = port.to_i

    @retry  = nil
    @status = 'NOT CONNECTED'
    @timeout = timeout
    @size = size
    
    @reserved_sockets = {}

    @mutex = Monitor.new
    @queue = @mutex.new_cond

    @sockets = []
    @checked_out = []
  end

  ##
  # Return a string representation of the server object.
  def inspect
    "<Redis::Server: %s:%d (%s)>" % [@host, @port, @status]
  end

  ##
  # Try to connect to the redis server targeted by this object.
  # Returns the connected socket object on success or nil on failure.

  def socket
    if socket = @reserved_sockets[current_connection_id]
      socket
    else
      @reserved_sockets[current_connection_id] = checkout
    end
  end

  def connect_to(host, port, timeout=nil)
    addrs = Socket.getaddrinfo(host, nil)
    addr = addrs.detect { |ad| ad[0] == 'AF_INET' }
    sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    if timeout
      secs = Integer(timeout)
      usecs = Integer((timeout - secs) * 1_000_000)
      optval = [secs, usecs].pack("l_2")
      sock.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, optval
      sock.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, optval
    end
    sock.connect(Socket.pack_sockaddr_in(port, addr[3]))
    sock
  end

  ##
  # Close the connection to the redis server targeted by this
  # object.  The server is not considered dead.

  def close
    @reserved_sockets.each do |name,sock|
      checkin sock
    end
    @reserved_sockets = {}
    @sockets.each do |sock|
      sock.close
    end
    @sockets = []
    @status = "NOT CONNECTED"
  end

  ##
  # Mark the server as dead and close its socket.
  def mark_dead(sock, error)
    sock.close if sock && !sock.closed?
    sock   = nil

    reason = "#{error.class.name}: #{error.message}"
    @status = sprintf "%s:%s DEAD (%s)", @host, @port, reason
    puts @status
  end

  protected
    def new_socket
      sock = nil
      begin
        sock = connect_to(@host, @port, @timeout)
        sock.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1
        @status = 'CONNECTED'
      rescue Errno::EPIPE, Errno::ECONNREFUSED => e
        if sock
          puts "Socket died... socket: #{sock.inspect}\n" if $debug
          sock.close
        end
      rescue SocketError, SystemCallError, IOError => err
        puts "Unable to open socket: #{err.class.name}, #{err.message}" if $debug
        mark_dead sock, err
      end

      return sock
    end

    def checkout
      @mutex.synchronize do
        loop do
          socket = if @checked_out.size < @sockets.size
                   checkout_existing_socket
                 elsif @sockets.size < @size
                   checkout_new_socket
                 end
          return socket if socket
          # No sockets available; wait for one
          if @queue.wait(@timeout)
            next
          else
            # try looting dead threads
            clear_stale_cached_sockets!
            if @size == @checked_out.size
              raise RedisError, "could not obtain a socket connection#{" within #{@timeout} seconds" if @timeout}.  The max pool size is currently #{@size}; consider increasing it."
            end
          end
        end
      end
    end

    def checkin(socket)
      @mutex.synchronize do
        @checked_out.delete socket
        @queue.signal
      end
    end

    def checkout_new_socket
      s = new_socket
      @sockets << s
      checkout_and_verify(s)
    end

    def checkout_existing_socket
      s = (@sockets - @checked_out).first
      checkout_and_verify(s)
    end

    def clear_stale_cached_sockets!
      remove_stale_cached_threads!(@reserved_sockets) do |name, socket|
        checkin socket
      end
    end

    def remove_stale_cached_threads!(cache, &block)
      keys = Set.new(cache.keys)

      Thread.list.each do |thread|
        keys.delete(thread.object_id) if thread.alive?
      end
      keys.each do |key|
        next unless cache.has_key?(key)
        block.call(key, cache[key])
        cache.delete(key)
      end
    end

  private
    def current_connection_id #:nodoc:
      Thread.current.object_id
    end

    def checkout_and_verify(s)
      s = verify!(s)
      @checked_out << s
      s
    end

    def verify!(s)
      reconnect!(s) unless active?(s)
    end

    def reconnect!(s)
      s.close
      connect_to(@host, @port, @timeout)
    end

    def active?(s)
      begin
        s.write("\0")
        Timeout.timeout(0.1){ s.read }
      rescue Exception
        false
      end
    end
end
