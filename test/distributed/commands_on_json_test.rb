# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnJson < Minitest::Test
  include Helper::DistributedModules
  include Lint::Json
end
