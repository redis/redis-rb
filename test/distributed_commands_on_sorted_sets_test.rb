# encoding: UTF-8

require "helper"
require "lint/sorted_sets"

class TestDistributedCommandsOnSortedSets < Test::Unit::TestCase

  include Helper
  include Helper::Distributed
  include Lint::SortedSets

  def test_zcount
    r.zadd "foo", 1, "s1"
    r.zadd "foo", 2, "s2"
    r.zadd "foo", 3, "s3"

    assert_equal 2, r.zcount("foo", 2, 3)
  end
end
