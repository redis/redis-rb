# frozen_string_literal: true

require "helper"

class TestClusterCommandsOnVectorSets < Minitest::Test
  include Helper::Cluster
  include Lint::VectorSets
end
