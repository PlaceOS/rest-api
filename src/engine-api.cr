require "option_parser"
require "http/client"

# Server defaults
port = 3000
host = "127.0.0.1"
cluster = false
process_count = 1

# Command line options
OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Usage: #{ACAEngine::Api::APP_NAME} [arguments]"

  parser.on("-b HOST", "--bind=HOST", "Specifies the server host") { |h| host = h }
  parser.on("-p PORT", "--port=PORT", "Specifies the server port") { |p| port = p.to_i }

  parser.on("-w COUNT", "--workers=COUNT", "Specifies the number of processes to handle requests") do |w|
    cluster = true
    process_count = w.to_i
  end

  parser.on("-r", "--routes", "List the application routes") do
    ActionController::Server.print_routes
    exit 0
  end

  parser.on("-v", "--version", "Display the application version") do
    puts "#{ACAEngine::Api::APP_NAME} v#{ACAEngine::Api::VERSION}"
    exit 0
  end

  parser.on("-c URL", "--curl=URL", "Perform a basic health check by requesting the URL") do |url|
    begin
      response = HTTP::Client.get url
      exit 0 if (200..499).includes? response.status_code
      puts "health check failed, received response code #{response.status_code}"
      exit 1
    rescue error
      error.inspect_with_backtrace(STDOUT)
      exit 2
    end
  end

  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end

  fail = ->(error : String, option : String) {
    STDERR.puts "#{error}: #{option}"
    puts parser
    exit 1
  }

  parser.missing_option { |o| fail.call("Error: Missing Option", o) }
  parser.invalid_option { |o| fail.call("Error: Invalid Option", o) }
end

# Load the routes
puts "Launching #{ACAEngine::Api::APP_NAME} v#{ACAEngine::Api::VERSION}"

# Requiring config here ensures that the option parser runs before
# we attempt to connect to redis etc.
require "./config"
server = ActionController::Server.new(port, host)

# Start clustering
server.cluster(process_count, "-w", "--workers") if cluster

terminate = Proc(Signal, Nil).new do |signal|
  puts " > terminating gracefully"
  spawn(same_thread: true) { server.close }
  signal.ignore
end

# Detect ctr-c to shutdown gracefully
Signal::INT.trap &terminate
# Docker containers use the term signal
Signal::TERM.trap &terminate

# Start the server
server.run do
  puts "Listening on #{server.print_addresses}"
  STDOUT.flush
end

# Shutdown message
puts "#{ACAEngine::Api::APP_NAME} leaps through the veldt\n"
