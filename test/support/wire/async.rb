require 'async'

class Wire
  def self.pass
    sleep(0)
  end
  
  def self.sleep(duration)
    Async::Task.current.sleep(duration)
  end

  def initialize(&block)
    @task = Async(&block)
  end

  def join
    @task.wait
  end
end
