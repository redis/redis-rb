# frozen_string_literal: true

require "helper"

class TestClusterCommandsOnArrays < Minitest::Test
  include Helper::Cluster
  include Lint::Arrays
end
