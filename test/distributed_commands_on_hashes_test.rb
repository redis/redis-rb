# encoding: UTF-8
# frozen_string_literal: true

require File.expand_path("helper", File.dirname(__FILE__))
require "lint/hashes"

class TestDistributedCommandsOnHashes < Test::Unit::TestCase

  include Helper::Distributed
  include Lint::Hashes
end
