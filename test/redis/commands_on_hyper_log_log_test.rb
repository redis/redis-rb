# frozen_string_literal: true

require "helper"

class TestCommandsOnHyperLogLog < Minitest::Test
  include Helper::Client
  include Lint::HyperLogLog
end
