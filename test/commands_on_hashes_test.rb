# frozen_string_literal: true
require_relative 'helper'
require_relative 'lint/hashes'

class TestCommandsOnHashes < Minitest::Test
  include Helper::Client
  include Lint::Hashes
end
