# frozen_string_literal: true

require "helper"

class TestCommandsOnSortedSets < Minitest::Test
  include Helper::Client
  include Lint::SortedSets
end
