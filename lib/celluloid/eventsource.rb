require 'celluloid/current'
require 'celluloid/eventsource/version'
require 'celluloid/io'
require 'celluloid/eventsource/response_parser'
require 'concurrent'
require 'logger'
require 'retries'
require 'uri'

module Celluloid
  class EventSource
    include Celluloid::IO
    Celluloid.boot

    attr_reader :url, :with_credentials, :heartbeat_timeout, :logger
    attr_reader :ready_state

    CONNECTING = 0
    OPEN = 1
    CLOSED = 2

    # 2^31 since our retries library doesn't allow for unlimited retries.
    # At an average of 1 second per retry, we'll still be retrying in 68 years.
    MAX_RETRIES = 2147483648

    execute_block_on_receiver :initialize

    def initialize(uri, options = {})
      self.url = uri
      options  = options.dup
      @ready_state = CONNECTING
      @with_credentials = options.delete(:with_credentials) { false }
      @heartbeat_timeout = options.delete(:heartbeat_timeout) { 300 }
      @logger = options.delete(:logger) { default_logger }
      @logger.info("[EventSource] Starting client connecting to url: #{self.url} with heartbeat timeout: #{@heartbeat_timeout} seconds")
      @headers = default_request_headers.merge(options.fetch(:headers, {}))

      @event_type_buffer = ""
      @last_event_id_buffer = ""
      @data_buffer = ""

      @last_event_id = String.new

      @reconnect_timeout = 1
      @on = { open: ->{}, message: ->(_) {}, error: ->(_) {}}
      @parser = ResponseParser.new

      @chunked = false

      yield self if block_given?

      async.listen
    end

    def url=(uri)
      @url = URI(uri)
    end

    def connected?
      ready_state == OPEN
    end

    def closed?
      ready_state == CLOSED
    end

    def listen
      while !closed?
        begin
          establish_connection
          chunked? ? process_chunked_stream : process_stream
        rescue Exception => e
          logger.debug("[EventSource] Reconnecting after exception: #{e}")
        end
        sleep @reconnect_timeout
      end
    end

    def listen_for_heartbeats
      @logger.debug("[EventSource] Starting listening for heartbeats. Reconnecting after #{@heartbeat_timeout} seconds if no comments are received")
      @heartbeat_task.cancel if @heartbeat_task
      @heartbeat_task = Concurrent::ScheduledTask.new(@heartbeat_timeout){
        @logger.warn("[EventSource] Didn't get heartbeat after #{@heartbeat_timeout} seconds. Reconnecting.")
        @socket.close if @socket
      }.execute
    end

    def close
      @logger.info("[EventSource] Closing client")
      @heartbeat_task.cancel if @heartbeat_task
      @socket.close if @socket
      @ready_state = CLOSED
    end

    def on(event_name, &action)
      @on[event_name.to_sym] = action
    end

    def on_open(&action)
      @on[:open] = action
    end

    def on_message(&action)
      @on[:message] = action
    end

    def on_error(&action)
      @on[:error] = action
    end

    private

    MessageEvent = Struct.new(:type, :data, :last_event_id)

    def ssl?
      url.scheme == 'https'
    end

    def establish_connection
      handler = Proc.new do |exception, attempt_number, total_delay|
        logger.warn("[EventSource] Could not connect with exception: #{exception.class} #{exception.message}; retry attempt #{attempt_number}; #{total_delay} seconds have passed.")
      end

      with_retries(:max_tries => MAX_RETRIES,
                   :base_sleep_seconds => 1.0,
                   :max_sleep_seconds => 30.0,
                   :handler => handler,
                   :rescue => Exception) do
        if !closed?
          @logger.info("[EventSource] Connecting to url: #{@url}")
          @socket = Celluloid::IO::TCPSocket.new(@url.host, @url.port)

          if ssl?
            @socket = Celluloid::IO::SSLSocket.new(@socket)
            @socket.connect
          end

          @socket.write(request_string)

          until @parser.headers?
            @parser << @socket.readline
          end

          if @parser.status_code != 200
            @socket.close if @socket
            raise "[EventSource] Could not connect to stream. Got status code: #{@parser.status_code}"
          end

          handle_headers(@parser.headers)
        end
      end
    end

    def default_request_headers
      {
        'Accept'        => 'text/event-stream',
        'Cache-Control' => 'no-cache',
        'Host'          => url.host
      }
    end

    def clear_buffers!
      @data_buffer = ""
      @event_type_buffer = ""
    end

    def dispatch_event(event)
      unless closed?
        @on[event.type] && @on[event.type].call(event)
      end
    end

    def chunked?
      @chunked
    end

    def process_chunked_stream
      until closed? || @socket.eof?
        handle_chunked_stream
      end
    end

    def process_stream
      until closed? || @socket.eof?
        line = @socket.readline
        line.strip.empty? ? process_event : parse_line(line)
      end
    end

    def handle_chunked_stream
      chunk_header = @socket.readline
      bytes_to_read = chunk_header.to_i(16)
      bytes_read = 0
      while bytes_read < bytes_to_read do
        line = @socket.readline
        bytes_read += line.size

        line.strip.empty? ? process_event : parse_line(line)
      end

      if !line.nil? && line.strip.empty?
        process_event
      end
    end

    def parse_line(line)
      case line
        when /^: ?(.*)$/
          @logger.debug("[EventSource] Got comment: #{$1}")
          listen_for_heartbeats
        when /^(\w+): ?(.*)$/
          process_field($1, $2)
        else
          if chunked? && !@data_buffer.empty?
            @data_buffer.rstrip!
            process_field("data", line.rstrip)
          end
      end
    end

    def process_event
      @last_event_id = @last_event_id_buffer

      return if @data_buffer.empty?

      @data_buffer.chomp!("\n") if @data_buffer.end_with?("\n")
      event = MessageEvent.new(:message, @data_buffer, @last_event_id)
      event.type = @event_type_buffer.to_sym unless @event_type_buffer.empty?

      @logger.debug("[EventSource] Dispatching event: #{event}")
      dispatch_event(event)
    ensure
      clear_buffers!
    end

    def process_field(field_name, field_value)
      case field_name
      when "event"
        @event_type_buffer = field_value
      when "data"
        @data_buffer << field_value.concat("\n")
      when "id"
        @last_event_id_buffer = field_value
      when "retry"
        if /^(?<num>\d+)$/ =~ field_value
          @reconnect_timeout = num.to_i
        end
      end
    end

    def handle_headers(headers)
      if headers['Content-Type'].include?("text/event-stream")
        @chunked = !headers["Transfer-Encoding"].nil? && headers["Transfer-Encoding"].include?("chunked")
        @ready_state = OPEN
        @on[:open].call
        @logger.info("[EventSource] Connected ok!")
        listen_for_heartbeats
      else
        @socket.close if @socket
        raise "Got invalid Content-Type header: #{headers['Content-Type']}. Expected text/event-stream"
      end
    end

    def request_string
      headers = @headers.map { |k, v| "#{k}: #{v}" }

      ["GET #{url.request_uri} HTTP/1.1", headers].flatten.join("\r\n").concat("\r\n\r\n")
    end

    def default_logger
      if defined?(Rails) && Rails.respond_to?(:logger)
        Rails.logger
      else
        log = ::Logger.new($stdout)
        log.level = ::Logger::INFO
        log
      end
    end

  end

end
