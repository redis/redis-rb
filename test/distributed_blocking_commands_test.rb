# encoding: UTF-8

require "helper"
require "lint/blocking_commands"

class TestDistributedBlockingCommands < Test::Unit::TestCase

  include Helper::Distributed
  include Lint::BlockingCommands
end
