# frozen_string_literal: true

require "mkmf"

# Off by default: building this extension does nothing unless explicitly requested, so
# `gem install redis`/`bundle install` never needs a C compiler for users who don't want
# local XXH3 digest computation (see Redis::XXH3 in lib/redis/xxh3.rb — DIGEST on the server
# covers the same need with one extra round trip). Opt in with:
#
#   gem install redis -- --enable-xxh3
#   bundle config build.redis --enable-xxh3   # then `bundle install`
#
if enable_config("xxh3", false)
  append_cflags("-O3")
  create_makefile("redis/xxh3/xxh3_ext")
else
  File.write("Makefile", dummy_makefile($srcdir).join) # rubocop:disable Style/GlobalVars
end
