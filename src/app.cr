require "option_parser"
require "http/client"

# Server defaults
port = 3000
host = "127.0.0.1"
cluster = false
process_count = 1

# Command line options
OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Usage: #{PlaceOS::Api::APP_NAME} [arguments]"

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

  parser.on("-e", "--env", "List the application environment") do
    ENV.accessed.sort.each &->puts(String)
    exit 0
  end

  parser.on("-v", "--version", "Display the application version") do
    puts "#{PlaceOS::Api::APP_NAME} v#{PlaceOS::Api::VERSION}"
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

  parser.on("-d", "--docs", "Outputs OpenAPI documentation for this service") do
    puts ActionController::OpenAPI.generate_open_api_docs(
      title: PlaceOS::Api::APP_NAME,
      version: PlaceOS::Api::API_VERSION,
      description: "PlaceOS REST-API description"
    ).to_yaml
    exit 0
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

# Requiring config here ensures that the option parser runs before
# we attempt to connect to redis etc.
require "./config"

# Configure the database connection. First check if PG_DATABASE_URL environment variable
# is set. If not, assume database configuration are set via individual environment variables
if pg_url = ENV["PG_DATABASE_URL"]?
  PgORM::Database.parse(pg_url)
else
  PgORM::Database.configure { |_| }
end

# Load the routes
PlaceOS::Api::Log.info { "launching #{PlaceOS::Api::APP_NAME} v#{PlaceOS::Api::VERSION} (#{PlaceOS::Api::BUILD_COMMIT} @ #{PlaceOS::Api::BUILD_TIME.strip})" }

server = ActionController::Server.new(port, host)

# Start clustering
server.cluster(process_count, "-w", "--workers") if cluster

terminate = Proc(Signal, Nil).new do |signal|
  puts " > terminating gracefully"
  spawn { server.close }
  signal.ignore
end

# Detect ctr-c to shutdown gracefully
Signal::INT.trap &terminate
# Docker containers use the term signal
Signal::TERM.trap &terminate

# Start the server
server.run do
  PlaceOS::Api::Log.info { "listening on #{server.print_addresses}" }
  STDOUT.flush
end

# Shutdown message
PlaceOS::Api::Log.info { "#{PlaceOS::Api::APP_NAME} leaps through the veldt" }
