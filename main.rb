require './tproxy'

begin
	Process.daemon(true, true)
	open('tproxy.pid', 'w') {|f| f << Process.pid}

	# logger = Logger.new('tproxy.log', 'daily')
	logger = Logger.new(STDOUT)
	logger.progname = 'tproxy'
	logger.level = Logger::Severity::INFO

	proxy = SimpleTProxy.new(
		:bind_address => '192.168.0.1',
		:logger       => logger
	)

	Signal.trap(:INT) { proxy.stop; puts 'The server is stopped by an interrupt.'; exit }
	Signal.trap(:TERM) { proxy.stop; exit }
	proxy.start
rescue => e
	puts e.full_message
end