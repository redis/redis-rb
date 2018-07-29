# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_commands_on_geo_test.rb
# @see https://redis.io/commands#geo
class TestClusterCommandsOnGeo < Test::Unit::TestCase
  include Helper::Cluster

  MIN_REDIS_VERSION = '3.2.0'

  def add_sicily
    redis.geoadd('Sicily',
                 13.361389, 38.115556, 'Palermo',
                 15.087269, 37.502669, 'Catania')
  end

  def test_geoadd
    target_version(MIN_REDIS_VERSION) do
      assert_equal 2, add_sicily
    end
  end

  def test_geohash
    target_version(MIN_REDIS_VERSION) do
      add_sicily
      assert_equal %w[sqc8b49rny0 sqdtr74hyu0], redis.geohash('Sicily', %w[Palermo Catania])
    end
  end

  def test_geopos
    target_version(MIN_REDIS_VERSION) do
      add_sicily
      expected = [%w[13.36138933897018433 38.11555639549629859],
                  %w[15.08726745843887329 37.50266842333162032],
                  nil]
      assert_equal expected, redis.geopos('Sicily', %w[Palermo Catania NonExisting])
    end
  end

  def test_geodist
    target_version(MIN_REDIS_VERSION) do
      add_sicily
      assert_equal '166274.1516', redis.geodist('Sicily', 'Palermo', 'Catania')
      assert_equal '166.2742', redis.geodist('Sicily', 'Palermo', 'Catania', 'km')
      assert_equal '103.3182', redis.geodist('Sicily', 'Palermo', 'Catania', 'mi')
    end
  end

  def test_georadius
    target_version(MIN_REDIS_VERSION) do
      add_sicily

      expected = [%w[Palermo 190.4424], %w[Catania 56.4413]]
      assert_equal expected, redis.georadius('Sicily', 15, 37, 200, 'km', 'WITHDIST')

      expected = [['Palermo', %w[13.36138933897018433 38.11555639549629859]],
                  ['Catania', %w[15.08726745843887329 37.50266842333162032]]]
      assert_equal expected, redis.georadius('Sicily', 15, 37, 200, 'km', 'WITHCOORD')

      expected = [['Palermo', '190.4424', %w[13.36138933897018433 38.11555639549629859]],
                  ['Catania', '56.4413', %w[15.08726745843887329 37.50266842333162032]]]
      assert_equal expected, redis.georadius('Sicily', 15, 37, 200, 'km', 'WITHDIST', 'WITHCOORD')
    end
  end

  def test_georadiusbymember
    target_version(MIN_REDIS_VERSION) do
      redis.geoadd('Sicily', 13.583333, 37.316667, 'Agrigento')
      add_sicily
      assert_equal %w[Agrigento Palermo], redis.georadiusbymember('Sicily', 'Agrigento', 100, 'km')
    end
  end
end
