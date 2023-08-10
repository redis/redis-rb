# frozen_string_literal: true

require "helper"

# ruby -w -Itest test/cluster_commands_on_pub_sub_test.rb
# @see https://redis.io/commands#pubsub
class TestClusterCommandsOnPubSub < Minitest::Test
  include Helper::Cluster

  def test_publish_subscribe_unsubscribe_pubsub
    sub_cnt = 0
    messages = {}

    thread = Thread.new do
      redis.subscribe('channel1', 'channel2') do |on|
        on.subscribe { sub_cnt += 1 }
        on.message do |c, msg|
          messages[c] = msg
          redis.unsubscribe if messages.size == 2
        end
      end
    end

    Thread.pass until sub_cnt == 2

    publisher = build_another_client

    assert_equal %w[channel1 channel2], publisher.pubsub(:channels, 'channel*')
    assert_equal({ 'channel1' => 1, 'channel2' => 1, 'channel3' => 0 },
                 publisher.pubsub(:numsub, 'channel1', 'channel2', 'channel3'))

    publisher.publish('channel1', 'one')
    publisher.publish('channel2', 'two')
    publisher.publish('channel3', 'three')

    thread.join

    assert_equal(2, messages.size)
    assert_equal('one', messages['channel1'])
    assert_equal('two', messages['channel2'])
  end

  def test_publish_psubscribe_punsubscribe_pubsub
    sub_cnt = 0
    messages = {}

    thread = Thread.new do
      redis.psubscribe('guc*', 'her*') do |on|
        on.psubscribe { sub_cnt += 1 }
        on.pmessage do |_ptn, c, msg|
          messages[c] = msg
          redis.punsubscribe if messages.size == 2
        end
      end
    end

    Thread.pass until sub_cnt == 2

    publisher = build_another_client

    assert_equal 2, publisher.pubsub(:numpat)

    publisher.publish('burberry1', 'one')
    publisher.publish('gucci2', 'two')
    publisher.publish('hermes3', 'three')

    thread.join

    assert_equal(2, messages.size)
    assert_equal('two', messages['gucci2'])
    assert_equal('three', messages['hermes3'])
  end
end
