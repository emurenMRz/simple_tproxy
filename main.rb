require './tproxy'

begin
	Process.daemon true, true
	open('tproxy.pid', 'w') {|f| f << Process.pid}

	# @server_log = Logger.new('tproxy.log', 'daily')
	@server_log = Logger.new STDOUT
	@server_log.progname = 'tproxy'
	@server_log.level = Logger::Severity::INFO

	proxy = SimpleTProxy.new logger: @server_log

	Signal.trap(:INT) { proxy.stop; puts 'The server is stopped by an interrupt.'; exit }
	Signal.trap(:TERM) { proxy.stop; exit }

	#
	# Output the response body to a file.
	# *This is a sample of content_hander.*
	#
	proxy.content_handler do |connect, request, response|
		type = response[:header]['Content-Type']
		return if type.nil?
		return if type != 'binary/octet-stream' && type[0, 12] != 'application/' && type[0, 6] != 'image/'

		body = response[:body]
		return if body.nil? || body.length == 0

		Thread.new(@server_log) do |server_log|
			begin
				host = request[:host]
				port = request[:port]
				path = request[:path]

				pos = path.index '?'
				path = path[0, pos] unless pos.nil?
				fpath = "#{host}/#{port}/#{path}"

				FileUtils.mkdir_p File.dirname(fpath)
				open(fpath, 'wb') do |ofile|
					content_encoding = response[:header]['Content-Encoding']
					if content_encoding == 'gzip'
						ofile.syswrite Zlib::Inflate.new(Zlib::MAX_WBITS + 32).inflate(body.string)
					else
						IO.copy_stream body, ofile
					end
				end
				server_log.info "#{connect} >> Output: #{fpath}"
			rescue
				server_log.error "#{connect} >>\n" + $!
			end
		end
	end

	proxy.start bind_address: '192.168.0.1', http_port: 8888, https_port: 0
rescue
	@server_log.error $!
	puts $!
end