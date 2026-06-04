# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnJson < Minitest::Test
  include Helper::Distributed
  include Lint::Json
end
