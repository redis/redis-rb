require_relative 'helper'
require_relative 'lint/hashes'

class TestDistributedCommandsOnHashes < Minitest::Test
  include Helper::Distributed
  include Lint::Hashes

  def test_hscan
    # Not implemented yet
  end

  def test_hstrlen
    # Not implemented yet
  end

  def test_mapped_hmget_in_a_pipeline_returns_hash
    assert_raises(Redis::Distributed::CannotDistribute) do
      super
    end
  end
end
