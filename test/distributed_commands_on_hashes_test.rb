require_relative "helper"
require_relative "lint/hashes"

class TestDistributedCommandsOnHashes < Test::Unit::TestCase

  include Helper::Distributed
  include Lint::Hashes
end
