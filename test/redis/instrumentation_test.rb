# frozen_string_literal: true

require "helper"
require "logger"
require "stringio"

class TestInstrumentation < Minitest::Test
  include Helper::Client

  def teardown
    Redis::Instrumentation.clear!
    super
  end

  def test_enabled_is_false_by_default
    assert_equal false, Redis::Instrumentation.enabled?
  end

  def test_registering_before_hook_enables
    Redis::Instrumentation.before_command { |_| }
    assert_equal true, Redis::Instrumentation.enabled?
  end

  def test_registering_after_hook_enables
    Redis::Instrumentation.after_command { |_| }
    assert_equal true, Redis::Instrumentation.enabled?
  end

  def test_registering_around_hook_enables
    Redis::Instrumentation.around_command { |_, call| call.call }
    assert_equal true, Redis::Instrumentation.enabled?
  end

  def test_clear_disables
    Redis::Instrumentation.before_command { |_| }
    Redis::Instrumentation.clear!
    assert_equal false, Redis::Instrumentation.enabled?
  end

  def test_before_hook_receives_event
    events = []
    Redis::Instrumentation.before_command { |event| events << event }

    r.set("foo", "bar")

    assert_equal 1, events.size
    event = events.first
    assert_equal "set", event.command_name
    assert_equal ["foo", "bar"], event.args
  end

  def test_after_hook_receives_result_and_duration
    events = []
    Redis::Instrumentation.after_command { |event| events << event }

    r.set("foo", "bar")

    assert_equal 1, events.size
    event = events.first
    assert_equal "set", event.command_name
    assert_equal "OK", event.result
    assert_kind_of Float, event.duration
    assert_operator event.duration, :>, 0
    refute event.error?
  end

  def test_after_hook_fires_on_error
    events = []
    Redis::Instrumentation.after_command { |event| events << event }

    assert_raises(Redis::CommandError) do
      r.call("INVALID_COMMAND_XXXXX")
    end

    assert_equal 1, events.size
    event = events.first
    assert event.error?
    assert_kind_of Exception, event.error
    assert_kind_of Float, event.duration
  end

  def test_around_hook_wraps_execution
    order = []
    Redis::Instrumentation.around_command do |_event, call|
      order << :before
      call.call
      order << :after
    end

    r.set("foo", "bar")

    assert_equal [:before, :after], order
  end

  def test_around_hooks_compose_in_registration_order
    order = []

    Redis::Instrumentation.around_command do |_event, call|
      order << :a_before
      call.call
      order << :a_after
    end

    Redis::Instrumentation.around_command do |_event, call|
      order << :b_before
      call.call
      order << :b_after
    end

    r.set("foo", "bar")

    assert_equal [:a_before, :b_before, :b_after, :a_after], order
  end

  def test_full_hook_ordering
    order = []

    Redis::Instrumentation.before_command { |_| order << :before }
    Redis::Instrumentation.around_command do |_, call|
      order << :around_pre
      call.call
      order << :around_post
    end
    Redis::Instrumentation.after_command { |_| order << :after }

    r.set("foo", "bar")

    assert_equal [:before, :around_pre, :around_post, :after], order
  end

  def test_event_redis_id
    events = []
    Redis::Instrumentation.after_command { |event| events << event }

    r.ping

    assert_equal r.id, events.first.redis_id
  end

  def test_command_is_frozen
    events = []
    Redis::Instrumentation.before_command { |event| events << event }

    r.set("foo", "bar")

    assert events.first.command.frozen?
  end

  def test_blocking_command_instrumented
    events = []
    Redis::Instrumentation.after_command { |event| events << event }

    r.lpush("list", "value")
    r.blpop("list", timeout: 1)

    blpop_event = events.find { |e| e.command_name == "blpop" }
    refute_nil blpop_event
    assert_kind_of Float, blpop_event.duration
  end

  def test_no_overhead_when_disabled
    Redis::Instrumentation.clear!
    assert_equal false, Redis::Instrumentation.enabled?

    r.set("foo", "bar")
    assert_equal "bar", r.get("foo")
  end

  def test_logger_hook
    io = StringIO.new
    logger = ::Logger.new(io)

    hook = Redis::Instrumentation::Hooks::Logger.new(logger: logger)
    hook.install!

    r.set("foo", "bar")

    output = io.string
    assert_match(/Redis SET/, output)
    assert_match(/ms/, output)
  end

  def test_logger_hook_with_filter
    io = StringIO.new
    logger = ::Logger.new(io)

    hook = Redis::Instrumentation::Hooks::Logger.new(
      logger: logger,
      filter: ->(cmd) { cmd == "get" }
    )
    hook.install!

    r.set("foo", "bar")
    r.get("foo")

    output = io.string
    refute_match(/SET/, output)
    assert_match(/GET/, output)
  end

  def test_logger_hook_rejects_invalid_level
    assert_raises(ArgumentError) do
      Redis::Instrumentation::Hooks::Logger.new(logger: ::Logger.new(StringIO.new), level: :bogus)
    end
  end

  def test_thread_safe_registration
    threads = 10.times.map do
      Thread.new do
        50.times do
          Redis::Instrumentation.before_command { |_| }
        end
      end
    end

    threads.each(&:join)

    assert Redis::Instrumentation.enabled?
  end

  def test_multiple_before_hooks_all_fire
    counts = [0, 0]
    Redis::Instrumentation.before_command { |_| counts[0] += 1 }
    Redis::Instrumentation.before_command { |_| counts[1] += 1 }

    r.ping

    assert_equal [1, 1], counts
  end

  def test_pipeline_commands_not_instrumented
    events = []
    Redis::Instrumentation.after_command { |event| events << event }

    r.pipelined do |p|
      p.set("foo", "bar")
      p.get("foo")
    end

    pipeline_events = events.select { |e| %w[set get].include?(e.command_name) }
    assert_equal 0, pipeline_events.size
  end

  # --- Hook error resilience tests ---

  def test_before_hook_error_does_not_break_command
    Redis::Instrumentation.before_command { |_| raise "boom" }

    result = r.set("foo", "bar")
    assert_equal "OK", result
  end

  def test_after_hook_error_does_not_break_command
    Redis::Instrumentation.after_command { |_| raise "boom" }

    result = r.set("foo", "bar")
    assert_equal "OK", result
  end

  def test_disconnect_hook_error_does_not_break_close
    Redis::Instrumentation.after_disconnect { |_| raise "boom" }

    r.ping
    r.close # should not raise
  end

  def test_broken_hook_does_not_prevent_other_hooks
    results = []
    Redis::Instrumentation.before_command { |_| raise "first hook fails" }
    Redis::Instrumentation.before_command { |_| results << :second_ran }

    r.ping

    assert_equal [:second_ran], results
  end

  # --- remove_hook tests ---

  def test_remove_hook_removes_before_hook
    hook = Redis::Instrumentation.before_command { |_| }
    assert Redis::Instrumentation.enabled?

    Redis::Instrumentation.remove_hook(hook)
    refute Redis::Instrumentation.enabled?
  end

  def test_remove_hook_removes_after_hook
    hook = Redis::Instrumentation.after_command { |_| }
    Redis::Instrumentation.remove_hook(hook)
    refute Redis::Instrumentation.enabled?
  end

  def test_remove_hook_removes_around_hook
    hook = Redis::Instrumentation.around_command { |_, call| call.call }
    Redis::Instrumentation.remove_hook(hook)
    refute Redis::Instrumentation.enabled?
  end

  def test_remove_hook_removes_disconnect_hook
    hook = Redis::Instrumentation.after_disconnect { |_| }
    Redis::Instrumentation.remove_hook(hook)
    refute Redis::Instrumentation.enabled?
  end

  def test_remove_hook_keeps_other_hooks_enabled
    hook1 = Redis::Instrumentation.before_command { |_| }
    hook2 = Redis::Instrumentation.before_command { |_| }

    Redis::Instrumentation.remove_hook(hook1)
    assert Redis::Instrumentation.enabled?

    Redis::Instrumentation.remove_hook(hook2)
    refute Redis::Instrumentation.enabled?
  end

  def test_remove_hook_prevents_hook_from_firing
    called = false
    hook = Redis::Instrumentation.after_command { |_| called = true }
    Redis::Instrumentation.remove_hook(hook)

    # Need another hook to keep instrumentation enabled
    Redis::Instrumentation.after_command { |_| }
    r.ping

    refute called
  end

  # --- around_command edge case ---

  def test_around_hook_not_calling_inner_prevents_execution
    Redis::Instrumentation.around_command do |_event, _call|
      # intentionally not calling _call.call
    end

    # The command won't actually execute through to Redis
    # but the hook chain completes without error
    events = []
    Redis::Instrumentation.after_command { |event| events << event }

    r.set("foo", "bar")

    # after hook still fires
    assert_equal 1, events.size
    # result is nil since inner was never called
    assert_nil events.first.result
  end

  # --- ParameterFilter tests ---

  def test_filter_auth_command_args
    filter = Redis::Instrumentation::ParameterFilter.new
    filtered = filter.filter_args("auth", ["mysecretpassword"])
    assert_equal ["[FILTERED]"], filtered
  end

  def test_filter_auth_with_username
    filter = Redis::Instrumentation::ParameterFilter.new
    filtered = filter.filter_args("auth", ["default", "mysecretpassword"])
    assert_equal ["[FILTERED]", "[FILTERED]"], filtered
  end

  def test_filter_config_set_requirepass
    filter = Redis::Instrumentation::ParameterFilter.new
    filtered = filter.filter_args("config", ["SET", "requirepass", "newsecret"])
    assert_equal ["SET", "requirepass", "[FILTERED]"], filtered
  end

  def test_filter_config_set_masterauth
    filter = Redis::Instrumentation::ParameterFilter.new
    filtered = filter.filter_args("config", ["SET", "masterauth", "newsecret"])
    assert_equal ["SET", "masterauth", "[FILTERED]"], filtered
  end

  def test_filter_config_get_not_filtered
    filter = Redis::Instrumentation::ParameterFilter.new
    filtered = filter.filter_args("config", ["GET", "maxmemory"])
    assert_equal ["GET", "maxmemory"], filtered
  end

  def test_filter_non_sensitive_command_passthrough
    filter = Redis::Instrumentation::ParameterFilter.new
    filtered = filter.filter_args("set", ["mykey", "myvalue"])
    assert_equal ["mykey", "myvalue"], filtered
  end

  def test_filter_custom_patterns_string
    filter = Redis::Instrumentation::ParameterFilter.new(patterns: [:password, :email])
    filtered = filter.filter_args("set", ["user:password:123", "secret"])
    assert_equal ["[FILTERED]", "secret"], filtered
  end

  def test_filter_custom_patterns_regexp
    filter = Redis::Instrumentation::ParameterFilter.new(patterns: [/credit.?card/i])
    filtered = filter.filter_args("set", ["user:credit_card", "4111111111111111"])
    assert_equal ["[FILTERED]", "4111111111111111"], filtered
  end

  def test_filter_custom_patterns_case_insensitive
    filter = Redis::Instrumentation::ParameterFilter.new(patterns: [:ssn])
    filtered = filter.filter_args("hset", ["user:1", "SSN", "123-45-6789"])
    assert_equal ["user:1", "[FILTERED]", "123-45-6789"], filtered
  end

  def test_filter_empty_args
    filter = Redis::Instrumentation::ParameterFilter.new
    filtered = filter.filter_args("ping", [])
    assert_equal [], filtered
  end

  def test_event_filtered_args_uses_global_filter
    saved_filter = Redis::Instrumentation.parameter_filter
    Redis::Instrumentation.parameter_filter = Redis::Instrumentation::ParameterFilter.new(patterns: [:secret])

    events = []
    Redis::Instrumentation.after_command { |event| events << event }

    r.set("my_secret_key", "value")

    event = events.first
    assert_equal ["my_secret_key", "value"], event.args
    assert_equal ["[FILTERED]", "value"], event.filtered_args
  ensure
    Redis::Instrumentation.parameter_filter = saved_filter
  end

  def test_event_filtered_args_auth_always_filtered
    events = []
    Redis::Instrumentation.before_command { |event| events << event }

    # Simulate an AUTH event by testing the filter directly on an Event
    cmd = [:auth, "mypassword"]
    event = Redis::Instrumentation::Event.new(cmd, "test-id")
    assert_equal ["[FILTERED]"], event.filtered_args
  end

  def test_event_filtered_args_is_memoized
    cmd = [:set, "key", "value"]
    event = Redis::Instrumentation::Event.new(cmd, "test-id")

    first_call = event.filtered_args
    second_call = event.filtered_args
    assert_same first_call, second_call
  end

  def test_logger_hook_with_log_args_filters_sensitive
    saved_filter = Redis::Instrumentation.parameter_filter
    Redis::Instrumentation.parameter_filter = Redis::Instrumentation::ParameterFilter.new(patterns: [:token])

    io = StringIO.new
    logger = ::Logger.new(io)

    hook = Redis::Instrumentation::Hooks::Logger.new(logger: logger, log_args: true)
    hook.install!

    r.set("api_token_cache", "secret_token_value")

    output = io.string
    # Both args contain "token", so both are filtered
    assert_match(/\[FILTERED\] \[FILTERED\]/, output)
    refute_match(/secret_token_value/, output)
  ensure
    Redis::Instrumentation.parameter_filter = saved_filter
  end

  def test_logger_hook_log_args_shows_non_sensitive
    io = StringIO.new
    logger = ::Logger.new(io)

    hook = Redis::Instrumentation::Hooks::Logger.new(logger: logger, log_args: true)
    hook.install!

    r.set("counter", "42")

    output = io.string
    assert_match(/SET counter 42/, output)
  end

  def test_parameter_filter_reset
    filter = Redis::Instrumentation::ParameterFilter.new(patterns: [:password])
    # First call compiles patterns
    filter.filter_args("set", ["password", "secret"])
    # Reset clears compiled cache
    filter.reset!
    # Still works after reset
    filtered = filter.filter_args("set", ["password", "secret"])
    assert_equal ["[FILTERED]", "secret"], filtered
  end

  # --- after_disconnect tests ---

  def test_after_disconnect_hook_fires_on_close
    ids = []
    Redis::Instrumentation.after_disconnect { |redis_id| ids << redis_id }

    redis_id = r.id
    r.close

    assert_equal [redis_id], ids
  end

  def test_after_disconnect_enables_instrumentation
    Redis::Instrumentation.clear!
    refute Redis::Instrumentation.enabled?

    Redis::Instrumentation.after_disconnect { |_| }
    assert Redis::Instrumentation.enabled?
  end

  def test_clear_removes_disconnect_hooks
    called = false
    Redis::Instrumentation.after_disconnect { |_| called = true }
    Redis::Instrumentation.clear!

    r.close
    refute called
  end

  def test_multiple_disconnect_hooks_all_fire
    counts = [0, 0]
    Redis::Instrumentation.after_disconnect { |_| counts[0] += 1 }
    Redis::Instrumentation.after_disconnect { |_| counts[1] += 1 }

    r.close

    assert_equal [1, 1], counts
  end

  # --- registration return value tests ---

  def test_before_command_returns_hook
    block = proc { |_| }
    result = Redis::Instrumentation.before_command(&block)
    assert_same block, result
  end

  def test_after_command_returns_hook
    block = proc { |_| }
    result = Redis::Instrumentation.after_command(&block)
    assert_same block, result
  end

  def test_around_command_returns_hook
    block = proc { |_, call| call.call }
    result = Redis::Instrumentation.around_command(&block)
    assert_same block, result
  end
end
