require_relative 'helper'
require_relative 'lint/lists'

class TestCommandsOnLists < Minitest::Test
  include Helper::Client
  include Lint::Lists
end
