class Redis
  class Subscription	
    def subscribe(&block)
      if block_given? then @subscribe = block else @subscribe end
    end
  
    def unsubscribe(&block)	
      if block_given? then @unsubscribe = block else @unsubscribe end
    end
  
    def message(&block)	
      if block_given? then @message = block else @message end
    end
  	
  end
end