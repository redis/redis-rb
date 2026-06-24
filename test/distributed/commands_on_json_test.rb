# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnJson < Minitest::Test
  include Helper::DistributedModules
  include Lint::Json

  # Multi-key atomic write cannot be guaranteed across nodes.
  def test_mset_cannot_be_distributed
    assert_raises(Redis::Distributed::CannotDistribute) do
      r.json_mset("doc1", "$", { "a" => 1 }, "doc2", "$", { "b" => 2 })
    end
  end
end
