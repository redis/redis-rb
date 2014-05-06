module Lint

  module HyperLogLog

    def test_pfadd
      target_version "2.8.9" do
        assert_equal true, r.pfadd("foo", "s1")
        assert_equal true, r.pfadd("foo", "s2")
        assert_equal false, r.pfadd("foo", "s1")

        assert_equal 2, r.pfcount("foo")
      end
    end

    def test_variadic_pfadd
      target_version "2.8.9" do
        assert_equal true, r.pfadd("foo", ["s1", "s2"])
        assert_equal true, r.pfadd("foo", ["s1", "s2", "s3"])

        assert_equal 3, r.pfcount("foo")
      end
    end

    def test_pfcount
      target_version "2.8.9" do
        assert_equal 0, r.pfcount("foo")

        assert_equal true, r.pfadd("foo", "s1")

        assert_equal 1, r.pfcount("foo")
      end
    end

    def test_variadic_pfcount
      target_version "2.8.9" do
        assert_equal 0, r.pfcount(["foo", "bar"])

        assert_equal true, r.pfadd("foo", "s1")
        assert_equal true, r.pfadd("bar", "s1")
        assert_equal true, r.pfadd("bar", "s2")

        assert_equal 2, r.pfcount(["foo", "bar"])
      end
    end

  end

end