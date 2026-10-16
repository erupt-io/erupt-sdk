# frozen_string_literal: true

require "socket"
require "stringio"

module Erupt
  # A small threaded HTTP/1.1 server (keep-alive, chunked request bodies) that runs a Rack application:
  # enough for the server-to-server traffic of a node, so the SDK needs no web server gem. To serve a node
  # from Puma, Rails or Sinatra, mount it there instead.
  class HttpServer
    MAX_BODY = 32 << 20
    MAX_LINE = 16 << 10
    MAX_HEADERS = 100
    IDLE_SECONDS = 30
    REASONS = { 100 => "Continue", 200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
                413 => "Payload Too Large", 500 => "Internal Server Error" }.freeze

    BadRequest = Class.new(StandardError)

    def initialize(app, host, port)
      @app, @port = app, port
      @server = TCPServer.new(host, port)
    end

    # Accept until the server is closed (or the thread is interrupted); one thread per connection.
    def run
      loop do
        client = @server.accept
        Thread.new(client) { |c| connection(c) }
      end
    rescue IOError, Errno::EBADF
      nil # closed
    end

    def close = @server.close

    private

    def connection(io)
      loop do
        env = read_request(io) or break
        status, headers, body = @app.call(env)
        keep_alive = keep_alive?(env)
        head = +"HTTP/1.1 #{status} #{REASONS[status]}\r\n"
        headers.each { |k, v| Array(v).each { |line| head << "#{k}: #{line}\r\n" } }
        io.write(head << "connection: #{keep_alive ? "keep-alive" : "close"}\r\n\r\n")
        body.each { |chunk| io.write(chunk) }
        body.close if body.respond_to?(:close)
        break unless keep_alive
      end
    rescue BadRequest => e
      io.write("HTTP/1.1 #{e.message} #{REASONS[e.message.to_i]}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
    rescue IOError, SystemCallError
      nil # the peer went away
    ensure
      io.close
    end

    def keep_alive?(env)
      connection = env["HTTP_CONNECTION"].to_s.downcase
      env["SERVER_PROTOCOL"] == "HTTP/1.1" ? !connection.include?("close") : connection.include?("keep-alive")
    end

    def read_request(io)
      return unless IO.select([io], nil, nil, IDLE_SECONDS)

      line = io.gets("\r\n", MAX_LINE) or return
      method, target, version = line.strip.split(" ", 3)
      raise BadRequest, "400" unless target && version&.start_with?("HTTP/")

      env = { "REQUEST_METHOD" => method, "SCRIPT_NAME" => "", "SERVER_PROTOCOL" => version,
              "SERVER_NAME" => "localhost", "SERVER_PORT" => @port.to_s, "REMOTE_ADDR" => io.peeraddr.last,
              "rack.url_scheme" => "http", "rack.errors" => $stderr }
      env["PATH_INFO"], env["QUERY_STRING"] = target.split("?", 2)
      env["QUERY_STRING"] ||= ""
      read_headers(io, env)
      io.write("HTTP/1.1 100 Continue\r\n\r\n") if env["HTTP_EXPECT"].to_s.casecmp?("100-continue")
      env["rack.input"] = StringIO.new(read_body(io, env))
      env
    end

    def read_headers(io, env)
      MAX_HEADERS.times do
        line = io.gets("\r\n", MAX_LINE) or raise BadRequest, "400"
        return if line == "\r\n"

        name, value = line.split(":", 2)
        raise BadRequest, "400" unless value

        key = name.strip.upcase.tr("-", "_")
        key = "HTTP_#{key}" unless %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)
        env[key] = env.key?(key) ? "#{env[key]}, #{value.strip}" : value.strip
      end
      raise BadRequest, "400"
    end

    def read_body(io, env)
      if env["HTTP_TRANSFER_ENCODING"].to_s.downcase.include?("chunked")
        body = +"".b
        while (size = io.gets("\r\n", MAX_LINE).to_s.to_i(16)).positive?
          raise BadRequest, "413" if body.bytesize + size > MAX_BODY

          body << io.read(size).to_s
          io.read(2)
        end
        nil while (trailer = io.gets("\r\n", MAX_LINE)) && trailer != "\r\n"
        return body
      end
      length = Integer(env["CONTENT_LENGTH"] || "0", 10, exception: false) or raise BadRequest, "400"
      raise BadRequest, "413" if length > MAX_BODY

      length.positive? ? io.read(length).to_s : +"".b
    end
  end
end
