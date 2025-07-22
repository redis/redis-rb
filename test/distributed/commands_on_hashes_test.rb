# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnHashes < Minitest::Test
  include Helper::Distributed
  include Lint::Hashes

  def test_mapped_hmget_in_a_pipeline_returns_hash
    assert_raises(Redis::Distributed::CannotDistribute) do
      super
    end
  end
end
