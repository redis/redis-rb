require_relative 'helper'
require_relative 'lint/sets'

class TestCommandsOnSets < Minitest::Test
  include Helper::Client
  include Lint::Sets
end
