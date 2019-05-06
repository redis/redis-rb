require_relative 'helper'
require_relative 'lint/strings'

class TestCommandsOnStrings < Minitest::Test
  include Helper::Client
  include Lint::Strings
end
