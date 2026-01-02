# frozen_string_literal: true

require "helper"

class TestCommandsOnJSON < Minitest::Test
  include Helper::Client
  include Lint::JSON
end
