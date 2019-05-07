# frozen_string_literal: true

require_relative 'helper'
require_relative 'lint/streams'

# ruby -w -Itest test/commands_on_streams_test.rb
# @see https://redis.io/commands#stream
class TestCommandsOnStreams < Minitest::Test
  include Helper::Client
  include Lint::Streams
end
