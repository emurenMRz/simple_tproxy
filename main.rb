require './tproxy'

begin
	Signal.trap('INT') {
		puts 'The server is stopped by an interrupt.'
		exit
	}
	SimpleTProxy.start('192.168.0.1')
rescue => e
	puts e.full_message
end