require_relative 'helper'
require_relative 'lint/lists'

class TestCommandsOnLists < Test::Unit::TestCase
  include Helper::Client
  include Lint::Lists
end
