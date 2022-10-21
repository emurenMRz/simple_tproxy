require 'socket'
require 'uri'
require 'fileutils'
require 'zlib'
require 'logger'
require 'stringio'

module HandshakeType
	ClientHello = 1
end

module ExtensionType
	ServerNameIndication = 0
end

class SimpleTProxy
	def initialize(logger: Logger.new(STDOUT))
		@logger = logger

		@content_handler = []
		@http_sock = nil
		@https_sock = nil
		@command_sock = nil
		@connections = {}
		@mutex = Mutex.new
	end

	#
	# request/response packets handler.
	#
	class ContentHandler
		attr_reader :host, :path, :handler

		def initialize(host, path, handler)
			@host = host
			@path = path
			@handler = handler
		end
	end

	def search_handler(host, path)
		@content_handler.find {|r| (r.host.nil? && r.path.nil?) || ((r.host.nil? || host.nil?) ? false : host.match?(r.host)) || ((r.path.nil? || path.nil?) ? false : path.match?(r.path))}
	end

	def content_handler(host: nil, path: nil, &handler)
		raise "Exists content_handler: #{host.nil? ? '' : host}#{path.nil? ? '' : path}" unless search_handler(host, path).nil?
		@content_handler.append ContentHandler.new(host, path, handler).freeze
	end

	#
	# Parse the Request/Response header.
	#
	def parse_header(sock)
		header = {}
		loop do
			line = sock.gets
			break if line.length <= 2
			pos = line.index(':')
			break if pos.nil?
			name = line[0, pos]
			value = line[(pos + 1) .. -1].strip!
			header[name] = value
		end
		header
	end

	#
	# Transfers the entity body.
	# If an IO object is specified, it is also copied to the specified IO object.
	#
	def transfers_entity_body(conn, header, src, dst, out_io = nil)
		content_length = header["Content-Length"].to_i
		transferred_bytes = 0
		if content_length > 0
			if out_io.nil?
				transferred_bytes = IO.copy_stream src, dst, content_length
			else
				transferred_bytes = IO.copy_stream src, out_io, content_length
				out_io.rewind
				transferred_bytes = IO.copy_stream out_io, dst, transferred_bytes
			end
		else
			transfer_encoding = header["Transfer-Encoding"]
			if transfer_encoding == 'chunked'
				chunk = nil
				chunk = StringIO.new unless out_io.nil?
				loop do
					len = src.gets
					dst.write len
					len = len.hex
					break if len == 0

					copied_bytes = 0
					if chunk.nil?
						copied_bytes = IO.copy_stream src, dst, len
					else
						chunk.rewind
						copied_bytes = IO.copy_stream src, chunk, len
						chunk.rewind
						copied_bytes = IO.copy_stream chunk, dst, copied_bytes
					end
					@logger.debug "#{conn} >> Transferred chunk size: #{copied_bytes} bytes"

					dst.write src.gets
					dst.flush

					unless chunk.nil?
						chunk.rewind
						IO.copy_stream chunk, out_io, copied_bytes
					end
					transferred_bytes += copied_bytes
				end
				dst.flush
				dst.write src.gets
				dst.flush
			elsif transfer_encoding.nil? == false
				raise "Unknown Transfer-Encoding: #{transfer_encoding}"
			end
		end
		out_io.rewind unless out_io.nil?
		@logger.debug "#{conn} >> Transferred total size: #{transferred_bytes} bytes"
		transferred_bytes
	end

	#
	# Receive HTTP request header from downstream.
	#
	def receive_request_header(from, sock)
		return nil if sock.nil? or sock.eof?
		start_line = sock.gets
		raise "Unable to receive request header." if start_line.nil?

		m = start_line.strip!.match /^(?<method>[A-Z]+) (?<path>[^ ]+) (?<http_version>HTTP\/1\.[01])$/
		raise "Unsupported HTTP request start line: #{start_line}" if m.nil?
		method = m[:method]
		path = m[:path]
		http_version = m[:http_version]
		protocol = 'http'
		host = nil
		port = 80
		if method == 'CONNECT'
			w = path.split(':')
			host = w[0]
			port = w[1].to_i
			protocol = 'https' if port == 443
		elsif path[0] != '/'
			uri = URI.parse(path)
			protocol = uri.scheme
			host = uri.host
			port = uri.port
			path = uri.path
		end
		@logger.debug "#{from} >> #{method} #{path} #{http_version}"

		header = parse_header sock
		@logger.debug "#{from} >> #{header.to_s}"

		host = header["Host"] if host.nil?
		raise "No Host header." if host.nil?

		keep_alive = http_version == 'HTTP/1.1'
		keep_alive = false if header['Connection'] == 'Close'
		if keep_alive && header['Keep-Alive'].kind_of?(String)
			max = header['Keep-Alive'].match(/max=([0-9]+)/).to_a[1].to_i
			keep_alive = false if max == 0
		end

		{
			:method => method,
			:path => path,
			:http_version => http_version,
			:header => header,
			:host => host,
			:keep_alive => keep_alive,
			:protocol => protocol,
			:port => port,
			:body => nil
		}
	end

	#
	# Send HTTP request header to upstream.
	#
	def send_request_header(request, sock)
		req = "#{request[:method]} #{request[:path]} #{request[:http_version]}\r\n"
		request[:header].each {|k, v| req += "#{k}: #{v}\r\n"}
		req += "\r\n"

		sock.write req
		sock.flush
	end

	#
	# Forwarding HTTP request.
	#
	def forward_http_request(conn)
		request = receive_request_header conn.from, conn.s_sock
		return nil if request.nil?

		content_handler = search_handler request[:host], request[:path]
		request[:body] = StringIO.new unless content_handler.nil?

		conn.open_host request[:host], request[:port]
		if request[:method] != 'CONNECT'
			send_request_header request, conn.d_sock
			transfers_entity_body conn.from, request[:header], conn.s_sock, conn.d_sock, request[:body]
		end

		[request, content_handler]
	end

	#
	# Receive HTTP response headers from upstream.
	#
	def receive_response_header(conn)
		raise "Disconnected from the remote host." if conn.d_sock.nil? or conn.d_sock.eof?
		start_line = conn.d_sock.gets
		raise "Unable to receive response header." if start_line.nil?

		m = start_line.strip!.match /^(?<http_version>HTTP\/1\.[01]) (?<status_code>[0-9]{3}) (?<reason>.+)$/
		raise "Unsupported HTTP response start line: #{start_line}" if m.nil?
		http_version = m[:http_version]
		status_code = m[:status_code]
		reason = m[:reason]
		@logger.debug "#{conn} >> #{http_version} #{status_code} #{reason}"

		header = parse_header(conn.d_sock)
		@logger.debug "#{conn} >> #{header.to_s}"

		{
			:http_version => http_version,
			:status_code => status_code,
			:reason => reason,
			:header => header,
			:body => nil
		}
	end

	#
	# Send HTTP response header to downstream.
	#
	def send_response_header(response, sock)
		res = "#{response[:http_version]} #{response[:status_code]} #{response[:reason]}\r\n"
		response[:header].each {|k, v| res += "#{k}: #{v}\r\n"}
		res += "\r\n"
		
		sock.write res
		sock.flush
	end

	#
	# Forwarding and parsing HTTP responses.
	#
	def forward_http_response(conn, snoop = false)
		response = receive_response_header conn

		response[:body] = StringIO.new if snoop
		
		send_response_header response, conn.s_sock
		transfers_entity_body conn, response[:header], conn.d_sock, conn.s_sock, response[:body]

		response
	end

	#
	# Proxy response to the CONNECT method.
	#
	def proxy_response_to_CONNECT(conn)
		response = {
			:http_version => 'HTTP/1.1',
			:status_code => '200',
			:reason => 'Connection established',
			:header => {},
			:body => nil
		}
		conn.s_sock.write "#{response[:http_version]} #{response[:status_code]} #{response[:reason]}\r\n\r\n"
		conn.s_sock.flush
		conn.protocol_handler = method(:https_handler)
		response
	end

	#
	# Handling HTTP sessions
	#
	def http_handler(conn)
		request, content_handler = forward_http_request(conn)
		return false if request.nil?

		if request[:method] == 'CONNECT'
			response = proxy_response_to_CONNECT conn
		elsif content_handler.nil?
			response = forward_http_response conn
		else
			response = forward_http_response conn, true
			content_handler.handler.call conn, request, response
		end

		@logger.info "#{conn} >> #{request[:method]} #{request[:path]} #{request[:http_version]} => #{response[:http_version]} #{response[:status_code]} #{response[:reason]}"
		request[:keep_alive]
	end

	#
	# TLS Packet class
	#
	class TLSPacket
		attr_reader :payload

		def initialize(sock)
			@content_type = sock.readbyte
			@version = sock.read(2)
			@length = sock.read(2)
			@payload = sock.read(length)
		end

		def content_type_n; @content_type; end
		def content_type
			case @content_type
			when 20; return 'ChangeCipherSpec'
			when 21; return 'Alert'
			when 22; return 'Handshake'
			when 23; return 'Application Data'
			end
			"Unknown type:#{@content_type}"
		end

		def version
			v = @version.unpack('n')[0]
			case v
			when 0x0200; return 'SSL 2.0'
			when 0x0300; return 'SSL 3.0'
			when 0x0301; return 'TLS 1.0'
			when 0x0302; return 'TLS 1.1'
			when 0x0303; return 'TLS 1.2'
			when 0x0304; return 'TLS 1.3'
			end
			"Unknown version:#{v}"
		end

		def length; @length.unpack('n')[0]; end
		def inspect; "#{content_type}:#{version}:#{length}"; end
		def to_s; [@content_type].pack('C') + @version + @length + @payload; end
	end

	class TLSError < StandardError
	end

	#
	# Get hostname from SNI
	#
	def open_host_by_SNI(conn)
		packet = TLSPacket.new(conn.s_sock)
		raise TLSError.new("Content Type is not Handshake: #{packet.inspect}") if packet.content_type_n != 22

		payload = StringIO.new(packet.payload)
		handshake_type = payload.readbyte.to_i
		raise TLSError.new("Handshake Type is not Client Hello: #{handshake_type}") if handshake_type != HandshakeType::ClientHello

		length = payload.read(3)
		version = payload.read(2)
		random = payload.read(32)
		session_id_length = payload.readbyte
		session_id = payload.read(session_id_length)
		cipher_suites_length = payload.read(2).unpack('n')[0]
		cipher_suites = payload.read(cipher_suites_length)
		compression_methods_length = payload.readbyte
		compression_methods = payload.read(compression_methods_length)
		extensions_length = payload.read(2).unpack('n')[0]
		while !payload.eof?
			extension_type = payload.read(2).unpack('n')[0]
			extension_length = payload.read(2).unpack('n')[0]
			if extension_type == ExtensionType::ServerNameIndication
				server_name_list_length = payload.read(2).unpack('n')[0]
				server_name_type = payload.readbyte
				server_name_length = payload.read(2).unpack('n')[0]
				server_name = payload.read(server_name_length)
				conn.open_host server_name, 443
				conn.d_sock.write(packet)
				conn.d_sock.flush
				@logger.info "#{conn} >> Connection #{packet.version}"
				break
			else
				payload.read(extension_length)
			end
		end
		raise TLSError.new("The remote host name cannot be identified by the TLS handshake.") if conn.d_sock.nil?
	end

	#
	# Handling HTTPS sessions
	#
	def https_handler(conn)
		open_host_by_SNI(conn) if conn.d_sock.nil?

		xsock = IO.select [conn.s_sock, conn.d_sock], [], [], 300
		return false if xsock.nil? or xsock.length == 0
		for s in xsock[0]
			if s == conn.s_sock
				forward_tls_packet conn, conn.s_sock, conn.d_sock
			elsif s == conn.d_sock
				forward_tls_packet conn, conn.d_sock, conn.s_sock
			else
				raise TLSError.new("Unknown socket: #{s.addr} <=> #{s.peeraddr}")
			end
		end
		true
	end

	#
	# Forwarding TLS packet
	# 
	def forward_tls_packet(conn, s_sock, d_sock)
		packet = TLSPacket.new(s_sock)
		@logger.debug "#{conn} >> #{packet.inspect}"
		d_sock.write packet
		d_sock.flush
	end
	
	#
	# Handling command sessions
	#
	def command_handler(s_sock)
		Thread.new do
			from = "#{s_sock.peeraddr[2]}:#{s_sock.peeraddr[1]}"
			request = {}
			begin
				request = receive_request_header from, s_sock
				raise 'failed parse.' if request.nil?
				raise 'unsupport method.' unless request[:method] == 'GET'
				raise 'unknown path.' unless request[:path] == '/status'

				body = []
				@mutex.synchronize {@connections.each {|k, v| body.push(v.status)}}

				body_s = "[#{body.join(',')}]"
				s_sock.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body_s.length}\r\nConnection: close\r\n\r\n#{body_s}"
				@logger.info "#{from} >> #{request[:method]} #{request[:path]} #{request[:http_version]}: Success"
			rescue => e
				s_sock.write 'HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n'
				@logger.info "#{from} >> #{request[:method]} #{request[:path]} #{request[:http_version]}: #{e.full_message}"
			ensure
				s_sock.flush
				s_sock.close
			end
		end
	end

	#
	# Connection class
	#
	class Connection
		attr_reader :s_sock, :d_sock, :from, :to, :update_time
		attr_writer :protocol_handler
	
		def initialize(s_sock, protocol_handler, &block)
			@s_sock = s_sock
			@d_sock = nil
			@from = "#{s_sock.peeraddr[2]}:#{s_sock.peeraddr[1]}"
			@to = "*No connect*"
			@close = true
			@protocol_handler = protocol_handler
			@update_time = Time.now
			block.call(self) if block_given?
		end
	
		def open_host(host_name, port = 80)
			return if @to == host_name
			@d_sock.close unless @d_sock.nil?
			@to = "#{host_name}:#{port}"
			@d_sock = Socket.tcp(host_name, port)
			@close = false unless @d_sock.nil?
		end
	
		def close
			@s_sock.close unless @s_sock.nil?
			@d_sock.close unless @d_sock.nil?
			@close = true
		end
	
		def alive?
			return false if @close
			dead = @s_sock.closed? || @d_sock.closed?
			close if dead
			!dead
		end

		def session; @protocol_handler.call(self); end
		def to_s; "#{@from} => #{@to}"; end
		def status; '{"from":"' + @from + '","to":"' + @to + '","begin":' + @update_time.to_i.to_s + '}'; end
	end
	
	#
	# Add New Connection
	#
	def add_new_connection(sock, protocol_handler)
		Thread.new do
			Connection.new(sock, protocol_handler) do |conn|
				@mutex.synchronize {@connections[conn.from] = conn}
				begin
					loop do
						keep_alive = conn.session
						break unless keep_alive
						break if IO.select([conn.s_sock, conn.d_sock], [], [], 300).length == 0
					end
				rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, TLSError => e
					@logger.error "#{conn} >> #{e.message}"
				rescue EOFError, Errno::ECONNRESET => e
					@logger.error "#{conn} >> #{e.inspect} #{e.backtrace[0]}"
				rescue => e
					@logger.error "#{conn} >>\n" + e.full_message
				ensure
					conn.close
				end
				@mutex.synchronize {
					@connections.delete conn.from
					@logger.info "#{conn} >> disconnection: #{@connections.length} remains."
				}
			end
		end
	end

	#
	# Start proxy server
	#
	def start(bind_address: nil, http_port: 8080, https_port: 8443, command_port: 0)
		@http_sock = TCPServer.open(bind_address, http_port) if http_port > 0
		@https_sock = TCPServer.open(bind_address, https_port) if https_port > 0
		@command_sock = TCPServer.open(bind_address, command_port) if command_port > 0
		ports = []
		ports.push(@http_sock) unless @http_sock.nil?
		ports.push(@https_sock) unless @https_sock.nil?
		ports.push(@command_sock) unless @command_sock.nil?

		accept_ports = 'HTTP: ' + (@http_sock.nil? ? 'No accept' : "#{@http_sock.addr[2]}:#{@http_sock.addr[1]}")
		accept_ports += ', HTTPS: ' + (@https_sock.nil? ? 'No accept' : "#{@https_sock.addr[2]}:#{@https_sock.addr[1]}")
		accept_ports += ', command: ' + (@command_sock.nil? ? 'No accept' : "#{@command_sock.addr[2]}:#{@command_sock.addr[1]}")
		@logger.info(accept_ports)

		begin
			loop do
				xsock = IO.select ports, [], [], 60
				if xsock.nil?
					@mutex.synchronize {
						prev_conn = @connections.length
						@connections.delete_if {|k, v| !v.alive?}
						remain_conn = @connections.length
						@logger.info("disconnection: #{prev_conn - remain_conn}(#{remain_conn} remains).") if prev_conn != remain_conn
					}
					next
				end
				for s in xsock[0]
					if !@http_sock.nil? and s == @http_sock; add_new_connection(s.accept, method(:http_handler))
					elsif !@https_sock.nil? and s == @https_sock; add_new_connection(s.accept, method(:https_handler))
					elsif !@command_sock.nil? and s == @command_sock; command_handler(s.accept)
					else raise "Unknown socket: #{s.addr}" end
				end
			end
		rescue
			@logger.error $!
		ensure
			stop
		end
	end

	#
	# Stop proxy server
	#
	def stop
		@http_sock.close unless @http_sock.nil?
		@https_sock.close unless @https_sock.nil?
		@command_sock.close unless @command_sock.nil?
		@http_sock = nil
		@https_sock = nil
		@command_sock = nil
	end
end
