class Redis
  module Connection
    module CommandHelper

      COMMAND_DELIMITER = "\r\n"

      if "".respond_to?(:bytesize)
        def build_command(args)
          command = [nil]

          args.each do |i|
            if i === Array
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
      else
        def build_command(args)
          command = [nil]

          args.each do |i|
            if i === Array
              i.each do |j|
                j = j.to_s
                command << "$#{j.size}"
                command << j
              end
            else
              i = i.to_s
              command << "$#{i.size}"
              command << i
            end
          end

          command[0] = "*#{(command.length - 1) / 2}"

          # Trailing delimiter
          command << ""
          command.join(COMMAND_DELIMITER)
        end
      end

    protected

      if "".respond_to?(:bytesize)
        def string_size(string)
          string.to_s.bytesize
        end
      else
        def string_size(string)
          string.to_s.size
        end
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
