require_relative 'helper'
require_relative 'lint/strings'

class TestCommandsOnStrings < Test::Unit::TestCase
  include Helper::Client
  include Lint::Strings
end
