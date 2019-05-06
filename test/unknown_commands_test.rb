require_relative "helper"

class TestUnknownCommands < Minitest::Test

  include Helper::Client

  def test_should_try_to_work
    assert_raises Redis::CommandError do
      r.not_yet_implemented_command
    end
  end
end
