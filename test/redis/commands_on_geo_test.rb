# frozen_string_literal: true

require "helper"

class TestCommandsGeo < Minitest::Test
  include Helper::Client

  def setup
    super

    added_items_count = r.geoadd("Sicily", 13.361389, 38.115556, "Palermo", 15.087269, 37.502669, "Catania")
    assert_equal 2, added_items_count
  end

  def test_geoadd_with_array_params
    added_items_count = r.geoadd("SicilyArray", [13.361389, 38.115556, "Palermo", 15.087269, 37.502669, "Catania"])
    assert_equal 2, added_items_count
  end

  def test_geoadd_with_nx_option
    target_version "6.2" do
      # NX only adds new members, never updates existing ones
      added = r.geoadd("Sicily", 14, 38, "Palermo", nx: true)
      assert_equal 0, added
      assert_equal [coordinates_palermo], r.geopos("Sicily", "Palermo")

      added = r.geoadd("Sicily", 2.349014, 48.864716, "Paris", nx: true)
      assert_equal 1, added
    end
  end

  def test_geoadd_with_xx_option
    target_version "6.2" do
      # XX only updates existing members, never adds new ones
      added = r.geoadd("Sicily", 2.349014, 48.864716, "Paris", xx: true)
      assert_equal 0, added
      assert_equal [nil], r.geopos("Sicily", "Paris")

      r.geoadd("Sicily", 14, 38, "Palermo", xx: true)
      refute_equal [coordinates_palermo], r.geopos("Sicily", "Palermo")
    end
  end

  def test_geoadd_with_ch_option
    target_version "6.2" do
      # CH returns the count of changed (added or updated) elements
      changed = r.geoadd("Sicily", 14, 38, "Palermo", 2.349014, 48.864716, "Paris", ch: true)
      assert_equal 2, changed
    end
  end

  def test_geoadd_with_both_nx_and_xx
    assert_raises(ArgumentError) do
      r.geoadd("Sicily", 14, 38, "Palermo", nx: true, xx: true)
    end
  end

  def test_georadius_with_same_params
    r.geoadd("Chad", 15, 15, "Kanem")
    nearest_cities = r.georadius("Chad", 15, 15, 15, 'km', sort: 'asc')
    assert_equal %w(Kanem), nearest_cities
  end

  def test_georadius_with_sort
    nearest_cities = r.georadius("Sicily", 15, 37, 200, 'km', sort: 'asc')
    assert_equal %w(Catania Palermo), nearest_cities

    farthest_cities = r.georadius("Sicily", 15, 37, 200, 'km', sort: 'desc')
    assert_equal %w(Palermo Catania), farthest_cities
  end

  def test_georadius_with_count
    city = r.georadius("Sicily", 15, 37, 200, 'km', count: 1)
    assert_equal %w(Catania), city
  end

  def test_georadius_with_options_count_sort
    city = r.georadius("Sicily", 15, 37, 200, 'km', sort: :desc, options: :WITHDIST, count: 1)
    assert_equal [["Palermo", "190.4424"]], city
  end

  def test_georadius_with_count_any
    target_version "6.2" do
      cities = r.georadius("Sicily", 15, 37, 200, 'km', count: 1, count_any: true)
      assert_equal 1, cities.size
      assert_includes %w(Catania Palermo), cities.first
    end
  end

  def test_georadiusbymember_with_sort
    nearest_cities = r.georadiusbymember("Sicily", "Catania", 200, 'km', sort: 'asc')
    assert_equal %w(Catania Palermo), nearest_cities

    farthest_cities = r.georadiusbymember("Sicily", "Catania", 200, 'km', sort: 'desc')
    assert_equal %w(Palermo Catania), farthest_cities
  end

  def test_georadiusbymember_with_count
    city = r.georadiusbymember("Sicily", "Catania", 200, 'km', count: 1)
    assert_equal %w(Catania), city
  end

  def test_georadiusbymember_with_options_count_sort
    city = r.georadiusbymember("Sicily", "Catania", 200, 'km', sort: :desc, options: :WITHDIST, count: 1)
    assert_equal [["Palermo", "166.2742"]], city
  end

  def test_georadiusbymember_with_count_any
    target_version "6.2" do
      cities = r.georadiusbymember("Sicily", "Catania", 200, 'km', count: 1, count_any: true)
      assert_equal 1, cities.size
      assert_includes %w(Catania Palermo), cities.first
    end
  end

  # GEOPOS/GEOSEARCH return coordinates as bulk strings under RESP2 but as doubles under RESP3.
  # Tests that only need the coordinate value use these helpers, which adapt to the active
  # protocol. Tests that specifically assert the per-protocol *type* live in the dedicated
  # `*_on_resp2` / `*_on_resp3` cases below.
  def coordinates_catania
    strings = if version >= "8.0"
      ["15.087267458438873", "37.50266842333162"]
    else
      ["15.08726745843887329", "37.50266842333162032"]
    end
    PROTOCOL == 3 ? strings.map(&:to_f) : strings
  end

  def coordinates_palermo
    strings = if version >= "8.0"
      ["13.361389338970184", "38.1155563954963"]
    else
      ["13.36138933897018433", "38.11555639549629859"]
    end
    PROTOCOL == 3 ? strings.map(&:to_f) : strings
  end

  def test_geopos
    location = r.geopos("Sicily", "Catania")
    assert_equal [coordinates_catania], location

    locations = r.geopos("Sicily", ["Palermo", "Catania"])
    assert_equal [coordinates_palermo, coordinates_catania], locations
  end

  # GEOPOS returns coordinates as bulk strings under RESP2 but as doubles under RESP3. This is an
  # intentional, protocol-dependent difference (we no longer coerce RESP3 doubles back to strings).
  def test_geopos_returns_string_coordinates_on_resp2
    skip("RESP2-specific behaviour") unless PROTOCOL == 2

    lon, lat = r.geopos("Sicily", "Catania").first
    assert_instance_of String, lon
    assert_instance_of String, lat
    assert_in_delta 15.0872, lon.to_f, 0.001
    assert_in_delta 37.5026, lat.to_f, 0.001
  end

  def test_geopos_returns_float_coordinates_on_resp3
    skip("RESP3-specific behaviour") unless PROTOCOL == 3

    lon, lat = r.geopos("Sicily", "Catania").first
    assert_instance_of Float, lon
    assert_instance_of Float, lat
    assert_in_delta 15.0872, lon, 0.001
    assert_in_delta 37.5026, lat, 0.001
  end

  def test_geopos_nonexistant_location
    location = r.geopos("Sicily", "Rome")
    assert_equal [nil], location

    locations = r.geopos("Sicily", ["Rome", "Catania"])
    assert_equal [nil, coordinates_catania], locations
  end

  def test_geodist
    distination_in_meters = r.geodist("Sicily", "Palermo", "Catania")
    assert_equal "166274.1516", distination_in_meters

    distination_in_feet = r.geodist("Sicily", "Palermo", "Catania", 'ft')
    assert_equal "545518.8700", distination_in_feet
  end

  def test_geodist_with_nonexistant_location
    distination = r.geodist("Sicily", "Palermo", "Rome")
    assert_nil distination
  end

  def test_geohash
    geohash = r.geohash("Sicily", "Palermo")
    assert_equal ["sqc8b49rny0"], geohash

    geohashes = r.geohash("Sicily", ["Palermo", "Catania"])
    assert_equal %w(sqc8b49rny0 sqdtr74hyu0), geohashes
  end

  def test_geohash_with_nonexistant_location
    geohashes = r.geohash("Sicily", ["Palermo", "Rome"])
    assert_equal ["sqc8b49rny0", nil], geohashes
  end

  def test_geosearch_with_frommember
    target_version "6.2" do
      members = r.geosearch("Sicily", frommember: "Catania", byradius: [200, "km"], sort: "asc")
      assert_equal %w(Catania Palermo), members
    end
  end

  def test_geosearch_with_fromlonlat
    target_version "6.2" do
      members = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"], sort: "asc")
      assert_equal %w(Catania Palermo), members
    end
  end

  def test_geosearch_with_byradius
    target_version "6.2" do
      members = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [100, "km"])
      assert_equal %w(Catania), members
    end
  end

  def test_geosearch_with_bybox
    target_version "6.2" do
      members = r.geosearch("Sicily", fromlonlat: [15, 37], bybox: [400, 400, "km"], sort: "asc")
      assert_equal %w(Catania Palermo), members
    end
  end

  def test_geosearch_with_sort
    target_version "6.2" do
      nearest = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"], sort: "asc")
      assert_equal %w(Catania Palermo), nearest

      farthest = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"], sort: "desc")
      assert_equal %w(Palermo Catania), farthest
    end
  end

  def test_geosearch_with_count
    target_version "6.2" do
      members = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"], sort: "asc", count: 1)
      assert_equal %w(Catania), members
    end
  end

  def test_geosearch_with_count_any
    target_version "6.2" do
      members = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"], count: 1, count_any: true)
      assert_equal 1, members.size
    end
  end

  def test_geosearch_with_withcoord_withdist_withhash
    target_version "6.2" do
      result = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"],
                                     sort: "asc", withcoord: true, withdist: true, withhash: true)
      assert_equal 2, result.size

      catania = result[0]
      assert_equal "Catania", catania[0]
      assert_equal "56.4413", catania[1]
      assert_kind_of Integer, catania[2]
      assert_equal coordinates_catania, catania[3]

      palermo = result[1]
      assert_equal "Palermo", palermo[0]
      assert_equal "190.4424", palermo[1]
      assert_kind_of Integer, palermo[2]
      assert_equal coordinates_palermo, palermo[3]
    end
  end

  # GEOSEARCH ... WITHCOORD returns the coordinate pair as bulk strings under RESP2 but as doubles
  # under RESP3 (the WITHDIST distance stays a string and WITHHASH stays an integer in both).
  def test_geosearch_withcoord_returns_string_coordinates_on_resp2
    skip("RESP2-specific behaviour") unless PROTOCOL == 2

    target_version "6.2" do
      _member, coord = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"],
                                             sort: "asc", withcoord: true).first
      assert_instance_of String, coord[0]
      assert_instance_of String, coord[1]
    end
  end

  def test_geosearch_withcoord_returns_float_coordinates_on_resp3
    skip("RESP3-specific behaviour") unless PROTOCOL == 3

    target_version "6.2" do
      _member, coord = r.geosearch("Sicily", fromlonlat: [15, 37], byradius: [200, "km"],
                                             sort: "asc", withcoord: true).first
      assert_instance_of Float, coord[0]
      assert_instance_of Float, coord[1]
    end
  end

  def test_geosearchstore_with_frommember
    target_version "6.2" do
      stored = r.geosearchstore("dest", "Sicily", frommember: "Catania", byradius: [200, "km"])
      assert_equal 2, stored
      assert_equal %w(Catania Palermo).sort, r.zrange("dest", 0, -1).sort
    end
  end

  def test_geosearchstore_with_fromlonlat
    target_version "6.2" do
      stored = r.geosearchstore("dest", "Sicily", fromlonlat: [15, 37], byradius: [200, "km"])
      assert_equal 2, stored
      assert_equal %w(Catania Palermo).sort, r.zrange("dest", 0, -1).sort
    end
  end

  def test_geosearchstore_with_byradius
    target_version "6.2" do
      stored = r.geosearchstore("dest", "Sicily", fromlonlat: [15, 37], byradius: [100, "km"])
      assert_equal 1, stored
      assert_equal %w(Catania), r.zrange("dest", 0, -1)
    end
  end

  def test_geosearchstore_with_bybox
    target_version "6.2" do
      stored = r.geosearchstore("dest", "Sicily", fromlonlat: [15, 37], bybox: [400, 400, "km"])
      assert_equal 2, stored
      assert_equal %w(Catania Palermo).sort, r.zrange("dest", 0, -1).sort
    end
  end

  def test_geosearchstore_with_sort_and_count
    target_version "6.2" do
      stored = r.geosearchstore("dest", "Sicily", fromlonlat: [15, 37], byradius: [200, "km"],
                                                  sort: "asc", count: 1)
      assert_equal 1, stored
      assert_equal %w(Catania), r.zrange("dest", 0, -1)
    end
  end

  def test_geosearchstore_with_storedist
    target_version "6.2" do
      stored = r.geosearchstore("dest", "Sicily", fromlonlat: [15, 37], byradius: [200, "km"],
                                                  storedist: true)
      assert_equal 2, stored
      with_scores = r.zrange("dest", 0, -1, withscores: true)
      assert_equal "Catania", with_scores[0][0]
      assert_in_delta 56.44, with_scores[0][1], 0.01
      assert_equal "Palermo", with_scores[1][0]
      assert_in_delta 190.44, with_scores[1][1], 0.01
    end
  end
end
