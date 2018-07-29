require_relative 'helper'
require_relative 'lint/sorted_sets'

class TestCommandsOnSortedSets < Test::Unit::TestCase
  include Helper::Client
  include Lint::SortedSets
end
