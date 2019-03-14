require_relative "../wire/async"

module Helper
  def around(&block)
    Async(&block).wait
  end
end
