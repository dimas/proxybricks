require 'socket'
require 'uri'
require 'openssl'

CRLF = "\r\n"
DOUBLE_CRLF = CRLF + CRLF

class HttpHeader
  attr_reader :name
  attr_accessor :value

  def initialize(name, value)
    @name = name
    @value = value
  end

  def http_data
    "#{name}: #{value}" + CRLF
  end

  def to_s
    "HttpHeader<#{@name}=#{@value}>"
  end
end

class HttpHeaderCollection

  def initialize()
    @headers = []
  end

  def add(name, value)
    @headers << HttpHeader.new(name, value)
  end

  def value(name)
    header = @headers.find { |h| h.name == name }
    header.nil? ? nil :header.value
  end

  def remove(name)
    @headers.delete_if { |h| h.name == name }
  end

  def replace(name, value)
    remove(name)
    add(name, value)
  end

  def http_data
    @headers.collect{|h| h.http_data}.join
  end

  def each
    @headers.each {|h| yield h }
  end
end

class HttpMessageParser

  attr_accessor :buffer
  attr_accessor :start_line
  attr_reader :headers

  def initialize()
    @buffer = ''
    @headers_read = false
    @headers = HttpHeaderCollection.new
  end

  def process_input(data)
    @buffer += data

    return if @headers_read

    eoh = buffer.index(DOUBLE_CRLF)
    if eoh then
      @headers_read = true
      parse_headers(@buffer.slice(0, eoh))
      @buffer = @buffer.slice(eoh + DOUBLE_CRLF.length .. -1)
    end
  end

  def headers_read?
    @headers_read
  end

  def http_data
    @start_line + CRLF + @headers.http_data + CRLF + @buffer
  end

  private

  def parse_headers(data)
    lines = data.split(CRLF);
    @start_line = lines.shift
    name = value = nil
    lines.each { |line|
      if line =~ /^ ([a-z0-9-]+) : \s* (.*) $/ix then
        @headers.add(name, value) unless name.nil?
        name = $1
        value = $2
      elsif line =~ /^ [ \t]+ (.*) $/x then
        raise "Invalid header, unexpected continuation: '#{line}'" if name.nil?
        value += $1
      else
        raise "Invalid header line: '#{line}'"
      end
    }
    @headers.add(name, value) unless name.nil?
  end
end

class HttpRequestParser < HttpMessageParser
  attr_reader :method, :uri, :protocol, :version

  def parse_headers(data)
    super
    unless start_line =~ / ^ (\w+) \s+ (\S+) \s+ (\w+)\/(1.\d) $ /x
      raise "Invalid request: #{start_line}"
      return
    end
    @method = $1
    @uri = $2
    @protocol = $3
    @version = $4
  end

  def method=(value)
    @method = value
    update_request_line
  end

  def uri=(value)
    @uri = value
    update_request_line
  end

  def protocol=(value)
    @protocol = value
    update_request_line
  end

  def version=(value)
    @version = value
    update_request_line
  end

  private

  def update_request_line
    @start_line = "#{@method} #{@uri} #{@protocol}/#{@version}"
  end

end

class HttpRequestHandler
  def handle(socket, request)
    raise "Not implemented"
  end
end

class Server
  def initialize(port)
    @handlers = []
    @port = port
  end

  def add_handler(prefix, handler)
    @handlers << [prefix, handler]
  end

  def run
    begin
      @socket = TCPServer.new @port
      
      loop do
        s = @socket.accept
        Thread.new s, &method(:handle_connection)
      end
      
    rescue Interrupt
      puts 'Interrupted'
    ensure
      if @socket
        @socket.close
        puts 'Socked closed..'
      end
      puts 'Quitting.'
    end
  end
  
  def handle_connection(client_socket)

    _, remote_port, _, remote_ip = client_socket.peeraddr
    puts "Reading from #{remote_ip}:#{remote_port}"

    begin

      request = read_request(client_socket)

      puts "#{request.start_line}"

      handle_request(client_socket, request)

    rescue => e
      puts "ERROR handling request from #{remote_ip}:#{remote_port}: #{e}"
      puts e
      puts e.backtrace
    ensure  
      client_socket.close
    end
  end

  def read_request(socket)
    parser = HttpRequestParser.new
    while not parser.headers_read? do
      ready = select([socket], nil, nil)
      buf = socket.read_nonblock(16384)
      parser.process_input(buf)
    end
    parser
  end

  def handle_request(socket, request)
    h = @handlers.find { |h| request.uri.start_with? h[0] }
    if h.nil? then
      socket.write("HTTP/1.1 404 Not Found\r\n");
      socket.write("Connection: close\r\n");
      socket.write("\r\n");
      socket.write("No handler for #{request.uri}.\n");
      return
    end

    h[1].handle(socket, request)
  end
  
end

class StaticFilesRequestHandler < HttpRequestHandler
  def initialize(base_dir)
    @base_dir = base_dir
  end

  def handle(socket, request)

    puts "Local request"

    path = request.uri
    path = path[1..-1] if path[0] == '/'

    file = File.join(@base_dir, path)

    if path.include? '/../' or path.start_with? '/' or not File.file? file then
      puts "Invalid request URI: #{path}"
      socket.write("HTTP/1.1 404 Not found\r\n");
      socket.write("Connection: close\r\n");
      socket.write("\r\n");
      return
    end

    puts "Sending file #{file}"

    data = File.read(file)  
    socket.write("HTTP/1.1 200 OK\r\n");
    socket.write("Content-Length: #{data.length}\r\n");
    socket.write("Connection: close\r\n");
    socket.write("\r\n");
    socket.write(data);

    puts "Sent #{path} => #{data.length} bytes"
  end
end

class ProxyingRequestHandler < HttpRequestHandler

  def initialize(target_host, target_port)
    @target_host = target_host
    @target_port = target_port
  end

  def modify_request(request)
    headers = request.headers
    # Host header refers to our server and JIRA won't like it so patch the request a bit
    headers.replace('Host', @target_host)
    # This class cannot handle multiple requests within same connection as it only parses the first one properly
    headers.replace('Connection', 'close')
  end

  def modify_response(response)
    # This class cannot handle multiple requests within same connection as it only parses the first one properly
    response.headers.replace('Connection', 'close')
  end

  def connect_target
    tcp_socket = TCPSocket.new(@target_host, @target_port)
    ssl_context = OpenSSL::SSL::SSLContext.new
    ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, ssl_context)
    ssl_socket.connect
    ssl_socket
  end

  def handle(client_socket, request)
    puts "Proxy request"

    modify_request(request)

    target_socket = connect_target
    begin
      # given we already have request, send what we got so far to the remote server before pumping data back and forth
      request_data = request.http_data
      target_socket.write(request_data)
puts ">>> #{request_data}"

      response = HttpMessageParser.new

      client_to_server_bytes = request_data.length
      server_to_client_bytes = 0
      loop do
        ready = select([target_socket, client_socket], nil, nil)
        if ready[0].include? client_socket
          # local > remote
          break if client_socket.eof?
          data = client_socket.read_nonblock(16384)
          target_socket.write(data)
          client_to_server_bytes += data.length
puts ">>> #{data}"
        end
        if ready[0].include? target_socket
          # remote > local
          break if target_socket.eof?
          data = target_socket.read_nonblock(16384)

            unless response.headers_read?
              response.process_input(data)
              # Wait for the end of the header
              next unless response.headers_read?
              modify_response(response)
              data = response.http_data
            end

            client_socket.write(data)
            server_to_client_bytes += data.length
puts "<<< #{data}"

        end
      end

      puts "Closing proxied request. client_to_server_bytes=#{client_to_server_bytes}, server_to_client_bytes=#{server_to_client_bytes}"

    ensure
      target_socket.close
    end
  end
end

