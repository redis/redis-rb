# frozen_string_literal: true

require "helper"

class TestCommandsOnHashes < Minitest::Test
  include Helper::Client
  include Lint::Hashes
end
