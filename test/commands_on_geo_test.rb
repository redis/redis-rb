require_relative "helper"

class TestCommandsGeo < Test::Unit::TestCase
  include Helper::Client

  def setup
    super
    r.geoadd("Sicily", 13.361389, 38.115556, "Palermo", 15.087269, 37.502669, "Catania")
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

  def test_geopos
    location = r.geopos("Sicily", "Catania")
    assert_equal [["15.08726745843887329", "37.50266842333162032"]], location

    locations = r.geopos("Sicily", ["Palermo", "Catania"])
    assert_equal [["13.36138933897018433", "38.11555639549629859"], ["15.08726745843887329", "37.50266842333162032"]], locations
  end

  def test_geopos_nonexistant_location
    location = r.geopos("Sicily", "Rome")
    assert_equal [nil], location

    locations = r.geopos("Sicily", ["Rome", "Catania"])
    assert_equal [nil, ["15.08726745843887329", "37.50266842333162032"]], locations
  end
end
