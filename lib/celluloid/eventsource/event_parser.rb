module Celluloid
  class EventSource
    class EventParser
      include Enumerable

      def initialize(lines, chunked, on_retry)
        @lines = lines
        @chunked = chunked
        clear_buffers!
        @on_retry = on_retry
      end

      def each
        @lines.each do |line|
          if line.strip.empty?
            begin
              event = create_event
              yield event unless event.nil?
            ensure
              clear_buffers!
            end
          else
            parse_line(line)
          end
        end
      end

      private

      MessageEvent = Struct.new(:type, :data, :id)

      def clear_buffers!
        @id_buffer = ''
        @data_buffer = ''
        @type_buffer = ''
      end

      def parse_line(line)
        case line
          when /^:.*$/
          when /^(\w+): ?(.*)$/
            process_field($1, $2)
          else
            if @chunked && !@data_buffer.empty?
              @data_buffer.rstrip!
              process_field("data", line.rstrip)
            end
        end
      end

      def create_event
        return nil if @data_buffer.empty?

        @data_buffer.chomp!("\n") if @data_buffer.end_with?("\n")
        event = MessageEvent.new(:message, @data_buffer, @id_buffer)
        event.type = @type_buffer.to_sym unless @type_buffer.empty?
        event
      end

      def process_field(field_name, field_value)
        case field_name
          when "event"
            @type_buffer = field_value
          when "data"
            @data_buffer << field_value.concat("\n")
          when "id"
            @id_buffer = field_value
          when "retry"
            if /^(?<num>\d+)$/ =~ field_value
              @on_retry.call(num.to_i)
            end
        end
      end
    end
  end
end
