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

  def coordinates_catania
    if version >= "8.0"
      ["15.087267458438873", "37.50266842333162"]
    else
      ["15.08726745843887329", "37.50266842333162032"]
    end
  end

  def coordinates_palermo
    if version >= "8.0"
      ["13.361389338970184", "38.1155563954963"]
    else
      ["13.36138933897018433", "38.11555639549629859"]
    end
  end

  def test_geopos
    location = r.geopos("Sicily", "Catania")
    assert_equal [coordinates_catania], location

    locations = r.geopos("Sicily", ["Palermo", "Catania"])
    assert_equal [coordinates_palermo, coordinates_catania], locations
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
end
