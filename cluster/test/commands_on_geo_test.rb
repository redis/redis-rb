# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_geo_test.rb
# @see https://redis.io/commands#geo
class TestClusterCommandsOnGeo < Minitest::Test
  include Helper::Cluster

  def add_sicily
    redis.geoadd('Sicily',
                 13.361389, 38.115556, 'Palermo',
                 15.087269, 37.502669, 'Catania')
  end

  def test_geoadd
    assert_equal 2, add_sicily
  end

  def test_geohash
    add_sicily
    assert_equal %w[sqc8b49rny0 sqdtr74hyu0], redis.geohash('Sicily', %w[Palermo Catania])
  end

  def test_geopos
    add_sicily

    expected = if version >= "8.0"
      [
        %w[13.361389338970184 38.1155563954963],
        %w[15.087267458438873 37.50266842333162],
        nil,
      ]
    else
      [
        %w[13.36138933897018433 38.11555639549629859],
        %w[15.08726745843887329 37.50266842333162032],
        nil,
      ]
    end
    assert_equal expected, redis.geopos('Sicily', %w[Palermo Catania NonExisting])
  end

  def test_geodist
    add_sicily
    assert_equal '166274.1516', redis.geodist('Sicily', 'Palermo', 'Catania')
    assert_equal '166.2742', redis.geodist('Sicily', 'Palermo', 'Catania', 'km')
    assert_equal '103.3182', redis.geodist('Sicily', 'Palermo', 'Catania', 'mi')
  end

  def test_georadius
    add_sicily

    expected = [%w[Palermo 190.4424], %w[Catania 56.4413]]
    assert_equal expected, redis.georadius('Sicily', 15, 37, 200, 'km', 'WITHDIST')

    expected = if version >= "8.0"
      [
        ['Palermo', %w[13.361389338970184 38.1155563954963]],
        ['Catania', %w[15.087267458438873 37.50266842333162]],
      ]
    else
      [
        ['Palermo', %w[13.36138933897018433 38.11555639549629859]],
        ['Catania', %w[15.08726745843887329 37.50266842333162032]],
      ]
    end
    assert_equal expected, redis.georadius('Sicily', 15, 37, 200, 'km', 'WITHCOORD')

    expected = if version >= "8.0"
      [
        ['Palermo', '190.4424', %w[13.361389338970184 38.1155563954963]],
        ['Catania', '56.4413', %w[15.087267458438873 37.50266842333162]],
      ]
    else
      [
        ['Palermo', '190.4424', %w[13.36138933897018433 38.11555639549629859]],
        ['Catania', '56.4413', %w[15.08726745843887329 37.50266842333162032]],
      ]
    end
    assert_equal expected, redis.georadius('Sicily', 15, 37, 200, 'km', 'WITHDIST', 'WITHCOORD')
  end

  def test_georadiusbymember
    redis.geoadd('Sicily', 13.583333, 37.316667, 'Agrigento')
    add_sicily
    assert_equal %w[Agrigento Palermo], redis.georadiusbymember('Sicily', 'Agrigento', 100, 'km')
  end
end
