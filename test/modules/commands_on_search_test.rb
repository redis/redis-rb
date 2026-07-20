# frozen_string_literal: true

require "helper"
require "lint/search"

# Runs the shared Query Engine (FT.*) suite against a module-capable standalone server.
class TestCommandsOnSearch < Minitest::Test
  include Helper::Modules
  include Lint::Search
end
