source 'https://rubygems.org'

gemspec

# Using jruby-openssl 0.10.0, we get NPEs in jruby tests: https://github.com/redis/redis-rb/issues/756
platform :jruby do
  gem 'jruby-openssl', '<0.10.0'
end
