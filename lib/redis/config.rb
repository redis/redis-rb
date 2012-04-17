require "redis/errors"

class Redis

  class Config

    DEFAULTS = {
      :scheme => "redis",
      :host => "127.0.0.1",
      :port => 6379,
      :path => nil,
      :timeout => 5.0,
      :password => nil,
      :db => 0,
    }

    def initialize(input = {})
      _set input.dup
    end

    def [](attr)
      _options[attr]
    end

    def []=(attr, value)
      _options[attr] = value
    end

    protected

    def _options
      @options ||= DEFAULTS.dup
    end

    def _set(input)
      url = input.delete(:url) || ENV["REDIS_URL"]

      _set_from_url(url) if url
      _set_from_input(input)
    end

    def _set_from_url(url)
      require "uri"

      uri = URI(url)

      if uri.scheme == "unix"
        _options[:path]   = uri.path
      else
        # Require the URL to have at least a host
        raise ArgumentError, "invalid url" unless uri.host

        _options[:scheme]   = uri.scheme
        _options[:host]     = uri.host
        _options[:port]     = uri.port if uri.port
        _options[:password] = uri.password if uri.password
        _options[:db]       = uri.path[1..-1].to_i if uri.path
      end
    end

    def _set_from_input(input)
      _options.merge!(input)

      if _options[:path]
        _options[:scheme] = "unix"
        _options.delete(:host)
        _options.delete(:port)
      end
    end
  end
end
