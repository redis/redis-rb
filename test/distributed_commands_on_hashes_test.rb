require_relative 'helper'
require_relative 'lint/hashes'

class TestDistributedCommandsOnHashes < Test::Unit::TestCase
  include Helper::Distributed
  include Lint::Hashes

  def test_mapped_hmget_in_a_pipeline_returns_hash
    assert_raise(Redis::Distributed::CannotDistribute) do
      super
    end
  end
end
