class Redis
  module Connection
    module ResponseHelper

      def array_expected_response?(response)
        response.respond_to?(:each_slice)
      end

      def string_expected_response?(response)
        response.respond_to?(:to_str) 
      end

      # add support for redis multi transaction response
      # validate if multi command queue a command successufully
      # all commands reply with the string QUEUED when does not exist an error
      # according with 
      # http://redis.io/commands/MULTI
      # http://redis.io/topics/transactions
      # redis.multi creates a transaction that is the native multi block implementation of redis.
      # To execute the commands you should call exec.
      # 
      # redis.multi
      # redis.[command]
      # redis.[command]
      # redis.exec
      #
      def command_queued_response?(response)
        response == 'QUEUED'
      end
    end
  end
end
