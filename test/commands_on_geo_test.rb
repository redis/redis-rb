require_relative "helper"

class TestCommandsGeo < Test::Unit::TestCase
  include Helper::Client

  def setup
    super

    target_version "3.2.0" do
      added_items_count = r.geoadd("Sicily", 13.361389, 38.115556, "Palermo", 15.087269, 37.502669, "Catania")
      assert_equal 2, added_items_count
    end
  end

  def test_georadius_with_sort
    target_version "3.2.0" do
      nearest_cities = r.georadius("Sicily", 15, 37, 200, 'km', sort: 'asc')
      assert_equal %w(Catania Palermo), nearest_cities

      farthest_cities = r.georadius("Sicily", 15, 37, 200, 'km', sort: 'desc')
      assert_equal %w(Palermo Catania), farthest_cities
    end
  end

  def test_georadius_with_count
    target_version "3.2.0" do
      city = r.georadius("Sicily", 15, 37, 200, 'km', count: 1)
      assert_equal %w(Catania), city
    end
  end

  def test_georadius_with_options_count_sort
    target_version "3.2.0" do
      city = r.georadius("Sicily", 15, 37, 200, 'km', sort: :desc, options: :WITHDIST, count: 1)
      assert_equal [["Palermo", "190.4424"]], city
    end
  end

  def test_georadiusbymember_with_sort
    target_version "3.2.0" do
      nearest_cities = r.georadiusbymember("Sicily", "Catania", 200, 'km', sort: 'asc')
      assert_equal %w(Catania Palermo), nearest_cities

      farthest_cities = r.georadiusbymember("Sicily", "Catania", 200, 'km', sort: 'desc')
      assert_equal %w(Palermo Catania), farthest_cities
    end
  end

  def test_georadiusbymember_with_count
    target_version "3.2.0" do
      city = r.georadiusbymember("Sicily", "Catania", 200, 'km', count: 1)
      assert_equal %w(Catania), city
    end
  end

  def test_georadiusbymember_with_options_count_sort
    target_version "3.2.0" do
      city = r.georadiusbymember("Sicily", "Catania", 200, 'km', sort: :desc, options: :WITHDIST, count: 1)
      assert_equal [["Palermo", "166.2742"]], city
    end
  end

  def test_geopos
    target_version "3.2.0" do
      location = r.geopos("Sicily", "Catania")
      assert_equal [["15.08726745843887329", "37.50266842333162032"]], location

      locations = r.geopos("Sicily", ["Palermo", "Catania"])
      assert_equal [["13.36138933897018433", "38.11555639549629859"], ["15.08726745843887329", "37.50266842333162032"]], locations
    end
  end

  def test_geopos_nonexistant_location
    target_version "3.2.0" do
      location = r.geopos("Sicily", "Rome")
      assert_equal [nil], location

      locations = r.geopos("Sicily", ["Rome", "Catania"])
      assert_equal [nil, ["15.08726745843887329", "37.50266842333162032"]], locations
    end
  end

  def test_geodist
    target_version "3.2.0" do
      distination_in_meters = r.geodist("Sicily", "Palermo", "Catania")
      assert_equal "166274.1516", distination_in_meters

      distination_in_feet = r.geodist("Sicily", "Palermo", "Catania", 'ft')
      assert_equal "545518.8700", distination_in_feet
    end
  end

  def test_geodist_with_nonexistant_location
    target_version "3.2.0" do
      distination = r.geodist("Sicily", "Palermo", "Rome")
      assert_equal nil, distination
    end
  end

  def test_geohash
    target_version "3.2.0" do
      geohash = r.geohash("Sicily", "Palermo")
      assert_equal ["sqc8b49rny0"], geohash

      geohashes = r.geohash("Sicily", ["Palermo", "Catania"])
      assert_equal %w(sqc8b49rny0 sqdtr74hyu0), geohashes
    end
  end

  def test_geohash_with_nonexistant_location
    target_version "3.2.0" do
      geohashes = r.geohash("Sicily", ["Palermo", "Rome"])
      assert_equal ["sqc8b49rny0", nil], geohashes
    end
  end
end
