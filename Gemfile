# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'minitest'
gem 'rake'
gem 'rubocop', '0.81'

# Using jruby-openssl 0.10.0, we get NPEs in jruby tests: https://github.com/redis/redis-rb/issues/756
platform :jruby do
  gem 'jruby-openssl', '<0.10.0'
end
