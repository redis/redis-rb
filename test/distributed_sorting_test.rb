require_relative "helper"

class TestDistributedSorting < Test::Unit::TestCase

  include Helper::Distributed

  def test_sort
    assert_raise(Redis::Distributed::CannotDistribute) do
      r.set("key1:1", "s1")
      r.set("key1:2", "s2")

      r.rpush("key4", "1")
      r.rpush("key4", "2")

      r.sort("key4", :get => "key1:*", :limit => [0, 1])
    end
  end
end
