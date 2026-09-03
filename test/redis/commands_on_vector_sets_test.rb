# frozen_string_literal: true

require "helper"

class TestCommandsOnVectorSets < Minitest::Test
  include Helper::Client
  include Lint::VectorSets

  def test_vadd_in_pipeline
    target_version "8.0" do
      first, second = r.pipelined do |pipe|
        pipe.vadd("foo", [0.1, 1.2, 0.5], "element")
        pipe.vadd("foo", [0.1, 1.2, 0.5], "element")
      end

      assert_equal true, first
      assert_equal false, second
    end
  end
end
