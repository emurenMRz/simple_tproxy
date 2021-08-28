require 'socket'
require 'fileutils'
require 'zlib'
require 'logger'

class Connection
	attr_reader :s_sock, :d_sock, :from, :to

	def initialize(s_sock, client_addrinfo, &block)
		@s_sock = s_sock
		@d_sock = nil
		@from = client_addrinfo.inspect_sockaddr
		@to = nil
		block.call(self) if block_given?
	end

	def open_host(host_name)
		return if @to == host_name
		@d_sock.close unless @d_sock.nil?
		@d_sock = Socket.tcp(host_name, 80)
		@to = host_name
	end

	def close
		@s_sock.close unless @s_sock.nil?
		@d_sock.close unless @d_sock.nil?
	end

	def to_s
		"#{@from} => #{@to}"
	end
end

class SimpleTProxy
	@@log = Logger.new(STDOUT)
	@@connections = {}

	#
	# Parse the Request/Response header.
	#
	def self.parse_header(sock)
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
		return header
	end

	#
	# Transfers the entity body.
	# If an IO object is specified, it is also copied to the specified IO object.
	#
	def self.transfers_entity_body(conn, header, src, dst, out_io = nil)
		content_length = header["Content-Length"].to_i
		transferred_bytes = 0
		if content_length > 0 then
			if out_io.nil? then
				transferred_bytes = IO.copy_stream(src, dst, content_length)
			else
				transferred_bytes = IO.copy_stream(src, out_io, content_length)
				out_io.rewind
				transferred_bytes = IO.copy_stream(out_io, dst, transferred_bytes)
			end
		else
			transfer_encoding = header["Transfer-Encoding"]
			if transfer_encoding == 'chunked' then
				chunk = nil
				chunk = StringIO.new unless out_io.nil?
				loop do
					len = src.gets
					dst.write(len)
					len = len.hex
					break if len == 0

					copied_bytes = 0
					if chunk.nil? then
						copied_bytes = IO.copy_stream(src, dst, len)
					else
						chunk.rewind
						copied_bytes = IO.copy_stream(src, chunk, len)
						chunk.rewind
						copied_bytes = IO.copy_stream(chunk, dst, copied_bytes)
					end
					@@log.debug("#{conn} >> Transferred chunk size: #{copied_bytes} bytes")

					dst.write(src.gets)
					dst.flush

					unless chunk.nil? then
						chunk.rewind
						IO.copy_stream(chunk, out_io, copied_bytes)
					end
					transferred_bytes += copied_bytes
				end
				dst.flush
				dst.write(src.gets)
				dst.flush
			elsif transfer_encoding.nil? == false then
				raise "Unknown Transfer-Encoding: #{transfer_encoding}"
			end
		end
		out_io.rewind unless out_io.nil?
		@@log.debug("#{conn} >> Transferred total size: #{transferred_bytes} bytes")
		return transferred_bytes
	end

	#
	# Receive HTTP request header from the client side.
	#
	def self.receive_request_header(from, sock)
		return nil if sock.nil? or sock.eof?
		recv_buf = sock.gets
		raise "Unable to receive request header." if recv_buf.nil?

		method, path, http_version = recv_buf.strip!.split
		@@log.debug("#{from} >> #{method} #{path} #{http_version}")

		header = parse_header(sock)
		@@log.debug("#{from} >> " + header.to_s)

		raise "Unsupport HTTP version: #{http_version}" unless http_version.match(/HTTP\/1\.[01]/)

		host = header["Host"]
		raise "No Host header." if host.nil?

		keep_alive = http_version == 'HTTP/1.1'
		keep_alive = false if header['Connection'] == 'Close'
		if keep_alive and header['Keep-Alive'].kind_of?(String) then
			max = header['Keep-Alive'].match(/max=([0-9]+)/).to_a[1].to_i
			keep_alive = false if max == 0
		end

		return {
			:method => method,
			:path => path,
			:http_version => http_version,
			:header => header,
			:host => host,
			:keep_alive => keep_alive
		}
	end

	#
	# Send HTTP request header to the server side.
	#
	def self.send_request_header(request, sock)
		req = "#{request[:method]} #{request[:path]} #{request[:http_version]}\r\n"
		request[:header].each {|k, v| req += "#{k}: #{v}\r\n"}
		req += "\r\n"

		sock.write(req)
		sock.flush
	end

	#
	# Forwarding HTTP request.
	#
	def self.forward_http_request(conn)
		request = receive_request_header(conn.from, conn.s_sock)
		return nil if request.nil?
		
		conn.open_host(request[:host])
		send_request_header(request, conn.d_sock)

		entity_body = StringIO.new
		transfers_entity_body(conn.from, request[:header], conn.s_sock, conn.d_sock, entity_body)
		request[:body] = entity_body
		return request
	end

	#
	# Forwarding and parsing HTTP responses.
	#
	def self.forward_http_response(conn)
		raise "Disconnected from the remote host." if conn.d_sock.nil? or conn.d_sock.eof?

		signature = ''
		conn.d_sock.read(4, signature)
		raise "Not HTTP: #{signature}" if signature != 'HTTP'

		res = signature + conn.d_sock.gets
		http_version, status_code, reason = res.strip!.split
		@@log.debug("#{conn} >> #{http_version} #{status_code} #{reason}")
		raise "Unsupport HTTP version: #{http_version}" if http_version != "HTTP/1.1"

		header = parse_header(conn.d_sock)
		@@log.debug("#{conn} >> " + header.to_s)
		header.each {|k, v| res += "#{k}: #{v}\r\n"}
		res += "\r\n"
		conn.s_sock.write(res)
		conn.s_sock.flush

		entity_body = StringIO.new
		transfers_entity_body(conn, header, conn.d_sock, conn.s_sock, entity_body)

		return {
			:http_version => http_version,
			:status_code => status_code,
			:reason => reason,
			:header => header,
			:body => entity_body
		}
	end

	#
	# Output the response body ?
	# 
	#
	def self.output_response_body?(request, respose)
		# == Example: Limit hosts
		# host = request[:host]
		# return false if host != 'example.com'

		# == Limit Content-Type
		type = respose[:header]['Content-Type']
		return false if type.nil?
		return false if type != 'binary/octet-stream' and type[0, 12] != 'application/' and type[0, 6] != 'image/'

		return true
	end

	#
	# Output the response body to a file.
	#
	def self.output_response_body(connect, request, response)
		return unless output_response_body?(request, response)

		body = response[:body]
		return if body.nil? or body.length == 0

		Thread.new {
			begin
				host = request[:host]
				path = request[:path]

				path.sub!(/^.+:\/\/.+?\//, '')
				path = path[1, path.length] if path[0] == '/'
				pos = path.index('?')
				path = path[0, pos] unless pos.nil?
				fpath = "#{host}/#{path}"

				FileUtils.mkdir_p(File.dirname(fpath))
				open(fpath, 'wb') {|ofile|
					content_encoding = response[:header]['Content-Encoding']
					if content_encoding == 'gzip' then
						ofile.syswrite(Zlib::Inflate.new(Zlib::MAX_WBITS + 32).inflate(body.string))
					else
						IO.copy_stream(body, ofile)
					end
				}
				@@log.info("#{connect} >> Output: #{fpath}")
			rescue => e
				@@log.error("#{connect} >>\n" + e.full_message)
			end
		}
	end

	#
	# Starting proxy server
	#
	def self.start(ipaddr = nil, port = 8081, log_name: nil, log_level: Logger::Severity::INFO)
		@@log = Logger.new(log_name, 'daily') unless log_name.nil?
		@@log.progname = 'tproxy'
		@@log.level = log_level
		Socket.tcp_server_loop(ipaddr, port) do |s_sock, client_addrinfo|
			Thread.new do
				Connection.new(s_sock, client_addrinfo) do |conn|
					@@connections[client_addrinfo.inspect_sockaddr] = conn
					begin
						loop do
							request = forward_http_request(conn)
							break if request.nil?
							
							response = forward_http_response(conn)
							output_response_body(conn, request, response)

							@@log.info("#{conn} >> #{request[:method]} #{request[:path]} #{request[:http_version]} => #{response[:http_version]} #{response[:status_code]} #{response[:reason]}")

							break unless request[:keep_alive]
							break if IO.select([conn.s_sock, conn.d_sock]).length == 0
						end
					rescue => e
						@@log.error("#{conn} >>\n" + e.full_message)
					ensure
						conn.close
					end
					@@connections.delete(client_addrinfo.inspect_sockaddr)
					@@log.info("#{conn} >> disconnection: #{@@connections.length} remains.")
				end
			end
		end
	end
end
