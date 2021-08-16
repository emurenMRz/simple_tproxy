require 'socket'
require 'fileutils'

class SimpleTProxy
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
	# Receive HTTP request from the client side.
	#
	def self.receive_http_request(sock)
		method, path, http_version = sock.gets.strip!.split
		puts "#{method} #{path} #{http_version}"

		header = parse_header(sock)
		pp header

		raise "Unsupport HTTP version: #{http_version}" unless http_version.match(/HTTP\/1\.[01]/)

		host = header["Host"]
		raise "No Host header." if host.nil?

		content_length = header["Content-Length"].to_i
		body = ''
		if content_length > 0 then
			sock.read(content_length, body)
			puts body
		end

		return {
			:method => method,
			:path => path,
			:http_version => http_version,
			:header => header,
			:host => host,
			:body => body
		}
	end

	#
	# Send HTTP request to the server side.
	#
	def self.send_http_request(request)
		req = "#{request[:method]} #{request[:path]} #{request[:http_version]}\r\n"
		request[:header].each {|k, v| req += "#{k}: #{v}\r\n"}
		req += "\r\n"

		sock = Socket.tcp(request[:host], 80)
		sock.write(req)
		sock.write(request[:body])
		sock.flush
		return sock
	end

	#
	# Forwarding and parsing HTTP responses.
	#
	def self.forward_http_response(d_sock, s_sock)
		signature = ''
		d_sock.read(4, signature)
		raise "Not HTTP: #{signature}" if signature != 'HTTP'

		res = d_sock.gets
		http_version, status_code, reason = res.strip!.split
		puts "#{signature}#{http_version} #{status_code} #{reason}"
		raise "Unsupport HTTP version: #{http_version}" if http_version != "/1.1"

		header = parse_header(d_sock)
		pp header
		header.each {|k, v| res += "#{k}: #{v}\r\n"}
		res += "\r\n"
		s_sock.write(signature + res)

		content_length = header["Content-Length"].to_i
		data = StringIO.new
		if content_length > 0 then
			copied_bytes = IO.copy_stream(d_sock, data, content_length)
			data.rewind
			copied_bytes = IO.copy_stream(data, s_sock, copied_bytes)
			puts "Transferred body size: #{copied_bytes} bytes"
		else
			transfer_encoding = header["Transfer-Encoding"]
			if transfer_encoding == 'chunked' then
				chunk = StringIO.new
				loop do
					len = d_sock.gets
					s_sock.write(len)
					len = len.hex
					break if len == 0

					chunk.rewind
					copied_bytes = IO.copy_stream(d_sock, chunk, len)
					chunk.rewind
					copied_bytes = IO.copy_stream(chunk, s_sock, copied_bytes)
					puts "Transferred chunk size: #{copied_bytes} bytes"

					s_sock.write(d_sock.gets)
					s_sock.flush

					chunk.rewind
					IO.copy_stream(chunk, data, copied_bytes)
				end
				s_sock.flush
				s_sock.write(d_sock.gets)
				s_sock.flush
			elsif transfer_encoding.nil? == false then
				raise "Unknown Transfer-Encoding: #{transfer_encoding}"
			end
		end

		return {
			:status_code => status_code,
			:reason => reason,
			:header => header,
			:body => data
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
		return false if type != 'binary/octet-stream' and type[0, 12] != 'application/' and type[0, 6] != 'image/'

		return true
	end

	#
	# Output the response body to a file.
	#
	def self.output_response_body(request, response)
		return unless output_response_body?(request, response)

		host = request[:host]
		path = request[:path]
		body = response[:body]
		body.rewind
		return if body.nil? or body.length == 0

		Thread.new {
			begin
				path.sub!(/^.+:\/\/.+?\//, '')
				path = path[1, path.length] if path[0] == '/'
				pos = path.index('?')
				path = path[0, pos] unless pos.nil?
				fpath = "#{host}/#{path}"

				puts "Output file: #{fpath}"
				FileUtils.mkdir_p(File.dirname(fpath))
				IO.copy_stream(body, open(fpath, 'wb'))
			rescue => e
				puts e.full_message
			end
		}
	end

	#
	# Starting proxy server
	#
	def self.start(ipaddr = nil, port = 8081)
		Socket.tcp_server_loop(ipaddr, port) {|s_sock, client_addrinfo|
			Thread.new {
				d_sock = nil
				begin
					puts "======================================"
					pp client_addrinfo

					request = receive_http_request(s_sock)
					d_sock = send_http_request(request)

					response = forward_http_response(d_sock, s_sock)
					output_response_body(request, response)
				rescue => e
					puts e.full_message
				ensure
					s_sock.close
					d_sock.close unless d_sock.nil?
				end
			}
		}
	end
end
