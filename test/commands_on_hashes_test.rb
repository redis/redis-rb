require_relative 'helper'
require_relative 'lint/hashes'

class TestCommandsOnHashes < Test::Unit::TestCase
  include Helper::Client
  include Lint::Hashes
end
