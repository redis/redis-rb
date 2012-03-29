class Redis
  module Connection
    module CommandHelper

      COMMAND_DELIMITER = "\r\n"

      def build_command(args)
        command = [nil]
        _build_multiword_command!(args)

        args.each do |i|
          if i.is_a? Array
            i.each do |j|
              j = j.to_s
              command << "$#{j.bytesize}"
              command << j
            end
          else
            i = i.to_s
            command << "$#{i.bytesize}"
            command << i
          end
        end

        command[0] = "*#{(command.length - 1) / 2}"

        # Trailing delimiter
        command << ""
        command.join(COMMAND_DELIMITER)
      end

    protected

      # Split a multiword command into an <tt>Array</tt>,
      # otherwise leave everything as is.
      #
      # Example:
      #    args # => [:script_load, 'return 0']
      #    _build_multiword_command!(args)
      #
      #    args # => [['script', 'load'], 'return 0']
      def _build_multiword_command!(args)
        command = args[0].to_s
        command = command.split('_') if command.match(/_/)
        args[0] = command
      end

      if defined?(Encoding::default_external)
        def encode(string)
          string.force_encoding(Encoding::default_external)
        end
      else
        def encode(string)
          string
        end
      end
    end
  end
end
