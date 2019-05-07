require_relative 'helper'
require_relative 'lint/sorted_sets'

class TestCommandsOnSortedSets < Minitest::Test
  include Helper::Client
  include Lint::SortedSets
end
