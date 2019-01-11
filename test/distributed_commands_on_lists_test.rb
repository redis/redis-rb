require_relative 'helper'
require_relative 'lint/lists'

class TestDistributedCommandsOnLists < Test::Unit::TestCase
  include Helper::Distributed
  include Lint::Lists

  def test_rpoplpush
    assert_raise Redis::Distributed::CannotDistribute do
      r.rpoplpush('key1', 'key4')
    end
  end

  def test_brpoplpush
    assert_raise Redis::Distributed::CannotDistribute do
      r.brpoplpush('key1', 'key4', timeout: 1)
    end
  end
end
