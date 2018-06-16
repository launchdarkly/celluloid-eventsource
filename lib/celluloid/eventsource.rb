require 'celluloid/current'
require 'celluloid/eventsource/version'
require 'celluloid/io'
require 'celluloid/eventsource/event_parser'
require 'celluloid/eventsource/response_parser'
require 'uri'
require 'base64'

module Celluloid
  class EventSource
    include Celluloid::IO
    include Celluloid::Internals::Logger
    Celluloid.boot

    class UnexpectedContentType < StandardError
    end

    class ReadTimeout < StandardError
    end

    attr_reader :url, :with_credentials
    attr_reader :ready_state

    CONNECTING = 0
    OPEN = 1
    CLOSED = 2

    MAX_RECONNECT_TIME = 30

    execute_block_on_receiver :initialize

    #
    # Constructor for an EventSource.
    #
    # @param uri [String] the event stream URI
    # @param opts [Hash] the configuration options
    # @option opts [Hash] :headers Headers to send with the request
    # @option opts [Float] :read_timeout Timeout (in seconds) after which to restart the connection if
    #  the server has sent no data
    # @option opts [Float] :reconnect_delay Initial delay (in seconds) between connection attempts; this will
    #  be increased exponentially if there are repeated failures
    #
    def initialize(uri, options = {})
      self.url = uri
      options  = options.dup
      @ready_state = CONNECTING
      @with_credentials = options.delete(:with_credentials) { false }
      @headers = default_request_headers.merge(options.fetch(:headers, {}))
      @read_timeout = options.fetch(:read_timeout, 0).to_i
      proxy = ENV['HTTP_PROXY'] || ENV['http_proxy'] || options[:proxy]
      if proxy
        proxyUri = URI(proxy)
        if proxyUri.scheme == 'http' || proxyUri.scheme == 'https'
          @proxy = proxyUri
        end
      end

      @reconnect_timeout = options.fetch(:reconnect_delay, 1)
      @on = { open: ->{}, message: ->(_) {}, error: ->(_) {} }

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
          process_stream
        rescue UnexpectedContentType
          raise  # Let these flow to the top
        rescue StandardError => e
          info "Reconnecting after exception: #{e}"
          # Just reconnect on runtime errors
        end
      end
    end

    def close
      @socket.close if @socket
      @socket = nil
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

    def ssl?
      url.scheme == 'https'
    end

    def establish_connection
      parser = ResponseParser.new
      reconnect_attempts = 0
      reconnect_jitter_rand = Random.new

      loop do
        begin
          if @proxy
            sock = ::TCPSocket.new(@proxy.host, @proxy.port)
            @socket = Celluloid::IO::TCPSocket.new(sock)

            @socket.write(connect_string)
            @socket.flush
            while (line = readline_with_timeout(@socket).chomp) != '' do parser << line end

            unless parser.status_code == 200
              @on[:error].call({status_code: parser.status_code, body: parser.chunk})
              return
            end
          else
            sock = ::TCPSocket.new(@url.host, @url.port)
            @socket = Celluloid::IO::TCPSocket.new(sock)
          end

          if ssl?
            @socket = Celluloid::IO::SSLSocket.new(@socket)
            @socket.connect
          end

          @socket.write(request_string)
          @socket.flush()

          until parser.headers?
            parser << readline_with_timeout(@socket)
          end

          if parser.status_code != 200
            close
            @on[:error].call({status_code: parser.status_code, body: parser.chunk})
          elsif parser.headers['Content-Type'] && parser.headers['Content-Type'].include?("text/event-stream")
            @chunked = !parser.headers["Transfer-Encoding"].nil? && parser.headers["Transfer-Encoding"].include?("chunked")
            @ready_state = OPEN
            @on[:open].call
            return  # Success, don't retry
          else
            close
            info "Invalid Content-Type #{parser.headers['Content-Type']}"
            @on[:error].call({status_code: parser.status_code, body: "Invalid Content-Type #{parser.headers['Content-Type']}. Expected text/event-stream"})
            raise UnexpectedContentType
          end

        rescue UnexpectedContentType
          raise  # Let these flow to the top

        rescue StandardError => e
          warn "Waiting to try again after exception while connecting: #{e}"
          # Just try again after a delay for any other exceptions
        end

        base_sleep_time = ([@reconnect_timeout * (2 ** reconnect_attempts), MAX_RECONNECT_TIME].min).to_f
        sleep_time = (base_sleep_time / 2) + reconnect_jitter_rand.rand(base_sleep_time / 2)
        sleep sleep_time
        reconnect_attempts += 1
      end
    end

    def default_request_headers
      {
        'Accept'        => 'text/event-stream',
        'Cache-Control' => 'no-cache',
        'Host'          => url.host
      }
    end

    def chunked?
      @chunked
    end

    def read_chunked_lines(socket)
      Enumerator.new do |lines|
        chunk_header = readline_with_timeout(socket)
        bytes_to_read = chunk_header.to_i(16)
        bytes_read = 0
        while bytes_read < bytes_to_read do
          line = readline_with_timeout(@socket)
          bytes_read += line.size
          lines << line
        end
      end
    end

    def read_lines
      Enumerator.new do |lines|
        loop do
          break if closed?
          if chunked?
            for line in read_chunked_lines(@socket) do
              break if closed?
              lines << line
            end
          else
            lines << readline_with_timeout(@socket)
          end
        end
      end
    end

    def process_stream
      parser = EventParser.new(read_lines, @chunked,->(timeout) { @read_timeout = timeout })
      parser.each do |event|
        @on[event.type] && @on[event.type].call(event)
        @last_event_id = event.id
      end
    end

    def readline_with_timeout(socket)
      if @read_timeout > 0
        begin
          timeout(@read_timeout) do
            socket.readline
          end
        rescue Celluloid::TaskTimeout
          @on[:error].call({body: "Read timeout, will attempt reconnection"})
          raise ReadTimeout
        end
      else
        return socket.readline
      end
    end

    def request_string
      headers = @headers.map { |k, v| "#{k}: #{v}" }

      ["GET #{url.request_uri} HTTP/1.1", headers].flatten.join("\r\n").concat("\r\n\r\n")
    end

    def connect_string
      req = "CONNECT #{url.host}:#{url.port} HTTP/1.1\r\n"
      req << "Host: #{url.host}:#{url.port}\r\n"
      if @proxy.user || @proxy.password
        encoded_credentials = Base64.strict_encode64([@proxy.user || '', @proxy.password || ''].join(":"))
        req << "Proxy-Authorization: Basic #{encoded_credentials}\r\n"
      end
      req << "\r\n"
    end
  end
end
