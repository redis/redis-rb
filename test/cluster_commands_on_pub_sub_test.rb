# frozen_string_literal: true

require_relative 'helper'

# ruby -w -Itest test/cluster_commands_on_pub_sub_test.rb
# @see https://redis.io/commands#pubsub
class TestClusterCommandsOnPubSub < Test::Unit::TestCase
  include Helper::Cluster

  def test_publish_subscribe_unsubscribe_pubsub
    sub_cnt = 0
    messages = {}

    wire = Wire.new do
      redis.subscribe('channel1', 'channel2') do |on|
        on.subscribe { |_c, t| sub_cnt = t }
        on.unsubscribe { |_c, t| sub_cnt = t }
        on.message do |c, msg|
          messages[c] = msg
          # FIXME: blocking occurs when `unsubscribe` method was called with channel arguments
          redis.unsubscribe if messages.size == 2
        end
      end
    end

    Wire.pass until sub_cnt == 2

    publisher = build_another_client

    assert_equal %w[channel1 channel2], publisher.pubsub(:channels)
    assert_equal %w[channel1 channel2], publisher.pubsub(:channels, 'cha*')
    assert_equal [], publisher.pubsub(:channels, 'chachacha*')
    assert_equal({}, publisher.pubsub(:numsub))
    assert_equal({ 'channel1' => 1, 'channel2' => 1, 'channel3' => 0 },
                 publisher.pubsub(:numsub, 'channel1', 'channel2', 'channel3'))
    assert_equal 0, publisher.pubsub(:numpat)

    publisher.publish('channel1', 'one')
    publisher.publish('channel2', 'two')

    wire.join

    assert_equal({ 'channel1' => 'one', 'channel2' => 'two' }, messages.sort.to_h)

    assert_equal [], publisher.pubsub(:channels)
    assert_equal [], publisher.pubsub(:channels, 'cha*')
    assert_equal [], publisher.pubsub(:channels, 'chachacha*')
    assert_equal({}, publisher.pubsub(:numsub))
    assert_equal({ 'channel1' => 0, 'channel2' => 0, 'channel3' => 0 },
                 publisher.pubsub(:numsub, 'channel1', 'channel2', 'channel3'))
    assert_equal 0, publisher.pubsub(:numpat)
  end

  def test_publish_psubscribe_punsubscribe_pubsub
    sub_cnt = 0
    messages = {}

    wire = Wire.new do
      redis.psubscribe('cha*', 'her*') do |on|
        on.psubscribe { |_c, t| sub_cnt = t }
        on.punsubscribe { |_c, t| sub_cnt = t }
        on.pmessage do |_ptn, chn, msg|
          messages[chn] = msg
          # FIXME: blocking occurs when `unsubscribe` method was called with channel arguments
          redis.punsubscribe if messages.size == 3
        end
      end
    end

    Wire.pass until sub_cnt == 2

    publisher = build_another_client

    assert_equal [], publisher.pubsub(:channels)
    assert_equal [], publisher.pubsub(:channels, 'cha*')
    assert_equal [], publisher.pubsub(:channels, 'her*')
    assert_equal [], publisher.pubsub(:channels, 'guc*')
    assert_equal({}, publisher.pubsub(:numsub))
    assert_equal({ 'channel1' => 0, 'channel2' => 0, 'hermes3' => 0, 'gucci4' => 0 },
                 publisher.pubsub(:numsub, 'channel1', 'channel2', 'hermes3', 'gucci4'))
    assert_equal 2, publisher.pubsub(:numpat)

    publisher.publish('chanel1', 'one')
    publisher.publish('chanel2', 'two')
    publisher.publish('hermes3', 'three')
    publisher.publish('gucci4', 'four')

    wire.join

    assert_equal({ 'chanel1' => 'one', 'chanel2' => 'two', 'hermes3' => 'three' }, messages.sort.to_h)

    assert_equal [], publisher.pubsub(:channels)
    assert_equal [], publisher.pubsub(:channels, 'cha*')
    assert_equal [], publisher.pubsub(:channels, 'her*')
    assert_equal [], publisher.pubsub(:channels, 'guc*')
    assert_equal({}, publisher.pubsub(:numsub))
    assert_equal({ 'channel1' => 0, 'channel2' => 0, 'hermes3' => 0, 'gucci4' => 0 },
                 publisher.pubsub(:numsub, 'channel1', 'channel2', 'hermes3', 'gucci4'))
    assert_equal 0, publisher.pubsub(:numpat)
  end
end
