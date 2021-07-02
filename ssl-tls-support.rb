SSL/TLS Support
This library supports natively terminating client side SSL/TLS connections when talking to Redis via a server-side proxy such as stunnel, hitch, or ghostunnel.

To enable SSL support, pass the :ssl => true option when configuring the Redis client, or pass in :url => "rediss://..." (like HTTPS for Redis). You will also need to pass in an :ssl_params => { ... } hash used to configure the OpenSSL::SSL::SSLContext object used for the connection:

redis = Redis.new(
  :url        => "rediss://:p4ssw0rd@10.0.1.1:6381/15",
  :ssl_params => {
    :ca_file => "/path/to/ca.crt"
  }
)
The options given to :ssl_params are passed directly to the OpenSSL::SSL::SSLContext#set_params method and can be any valid attribute of the SSL context. Please see the OpenSSL::SSL::SSLContext documentation for all of the available attributes.

Here is an example of passing in params that can be used for SSL client certificate authentication (a.k.a. mutual TLS):

redis = Redis.new(
  :url        => "rediss://:p4ssw0rd@10.0.1.1:6381/15",
  :ssl_params => {
    :ca_file => "/path/to/ca.crt",
    :cert    => OpenSSL::X509::Certificate.new(File.read("client.crt")),
    :key     => OpenSSL::PKey::RSA.new(File.read("client.key"))
  }
)
NOTE: SSL is only supported by the default "Ruby" driver
