# encoding: UTF-8

require_relative "helper"
require "lint/hashes"

class TestDistributedCommandsOnHashes < Test::Unit::TestCase

  include Helper::Distributed
  include Lint::Hashes
end
