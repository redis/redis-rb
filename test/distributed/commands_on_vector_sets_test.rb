# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnVectorSets < Minitest::Test
  include Helper::Distributed
  include Lint::VectorSets
end
