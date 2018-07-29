require_relative 'helper'
require_relative 'lint/sets'

class TestCommandsOnSets < Test::Unit::TestCase
  include Helper::Client
  include Lint::Sets
end
