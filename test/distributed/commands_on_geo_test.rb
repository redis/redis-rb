# frozen_string_literal: true

require "helper"

class TestDistributedCommandsOnGeo < Minitest::Test
  include Helper::Distributed

  def setup
    super

    added = r.geoadd("Sicily", 13.361389, 38.115556, "Palermo", 15.087269, 37.502669, "Catania")
    assert_equal 2, added
  end

  def test_geoadd_with_array_params
    added = r.geoadd("SicilyArray", [13.361389, 38.115556, "Palermo", 15.087269, 37.502669, "Catania"])
    assert_equal 2, added
  end

  def test_geoadd_with_nx_xx_ch_options
    target_version "6.2" do
      assert_equal 0, r.geoadd("Sicily", 14, 38, "Palermo", nx: true)
      assert_equal 1, r.geoadd("Sicily", 2.349014, 48.864716, "Paris", ch: true)
      assert_equal 0, r.geoadd("Sicily", 1, 1, "Rome", xx: true)
    end
  end

  def test_geohash
    assert_equal %w(sqc8b49rny0 sqdtr74hyu0), r.geohash("Sicily", %w(Palermo Catania))
  end

  def test_geopos
    location = r.geopos("Sicily", "Palermo")
    assert_equal 1, location.size
    assert_equal 2, location.first.size
  end

  def test_geodist
    assert_equal "166274.1516", r.geodist("Sicily", "Palermo", "Catania")
    assert_equal "166.2742", r.geodist("Sicily", "Palermo", "Catania", "km")
  end

  def test_georadius
    nearest = r.georadius("Sicily", 15, 37, 200, "km", sort: "asc")
    assert_equal %w(Catania Palermo), nearest
  end

  def test_georadiusbymember
    nearest = r.georadiusbymember("Sicily", "Catania", 200, "km", sort: "asc")
    assert_equal %w(Catania Palermo), nearest
  end

  def test_georadius_with_count_any
    target_version "6.2" do
      cities = r.georadius("Sicily", 15, 37, 200, "km", count: 1, count_any: true)
      assert_equal 1, cities.size
      assert_includes %w(Catania Palermo), cities.first
    end
  end

  def test_geosearch
    target_version "6.2" do
      members = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"], sort: "asc")
      assert_equal %w(Catania Palermo), members
    end
  end

  def test_geosearchstore_same_node
    target_version "6.2" do
      r.geoadd("{tag}.src", 13.361389, 38.115556, "Palermo", 15.087269, 37.502669, "Catania")
      stored = r.geosearchstore("{tag}.dest", "{tag}.src", fromlonlat: [15, 37], byradius: [200, "km"])
      assert_equal 2, stored
    end
  end

  def test_geosearchstore_cross_node_raises
    target_version "6.2" do
      assert_raises(Redis::Distributed::CannotDistribute) do
        r.geosearchstore("dest", "Sicily", fromlonlat: [15, 37], byradius: [200, "km"])
      end
    end
  end
end
