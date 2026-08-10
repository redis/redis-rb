# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnArrays < Minitest::Test
  include Helper::Distributed
  include Lint::Arrays
end
