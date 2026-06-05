# frozen_string_literal: true

require "helper"

class TestCommandsOnJson < Minitest::Test
  include Helper::Modules
  include Lint::Json

  def test_get_in_pipeline_returns_parsed_object
    r.json_set("doc", "$", { "a" => 1 })

    result = r.pipelined do |pipe|
      pipe.json_get("doc")
    end

    assert_equal({ "a" => 1 }, result.first)
  end

  def test_set_with_nx_in_pipeline_resolves_to_boolean
    result = r.pipelined do |pipe|
      pipe.json_set("doc", "$", { "a" => 1 }, nx: true)
    end

    assert_equal true, result.first
  end
end
