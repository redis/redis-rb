# encoding: UTF-8

require "helper"
require "lint/hashes"

class TestDistributedCommandsOnHashes < Test::Unit::TestCase

  include Helper::Distributed
  include Lint::Hashes
end
