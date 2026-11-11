require "json"
require "net/http"
require "uri"

# The parts of App Store Connect that fastlane does not cover: the app's price (free) and availability.
# Every step first looks at what is there and only creates what is missing, so the lane can run again and
# again; prices and territories that already exist are never touched (change them in App Store Connect).
module AppStoreConnect
  class Error < StandardError
    attr_reader :status

    def initialize(status, body)
      @status = status
      super("App Store Connect answered #{status}: #{body}")
    end
  end

  class Client
    BASE = "https://api.appstoreconnect.apple.com".freeze
    METHODS = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch, put: Net::HTTP::Put,
                delete: Net::HTTP::Delete }.freeze

    # `token` returns a current bearer token for every request.
    def initialize(token, base: BASE)
      @token = token
      @base = base
    end

    def get(path, params = {})
      request(:get, path, params: params)
    end

    # nil when App Store Connect answers 404 (nothing there yet).
    def get_if_exists(path)
      request(:get, path, allow_missing: true)
    end

    def post(path, body)
      request(:post, path, body: body)
    end

    def patch(path, body)
      request(:patch, path, body: body)
    end

    # Already gone counts as deleted.
    def delete(path)
      request(:delete, path, allow_missing: true)
    end

    # Walks `links.next` until the block finds something; returns it or nil.
    def find(path, params = {})
      page = get(path, params)
      loop do
        page["data"].each { |item| return item if yield(item) }
        following = page.dig("links", "next")
        return nil unless following
        page = request(:get, following)
      end
    end

    def all(path, params = {})
      items = []
      find(path, params) { |item| items << item && false }
      items
    end

    private

    def request(method, path, params: {}, body: nil, allow_missing: false)
      uri = URI(path.start_with?("http") ? path : @base + path)
      uri.query = URI.encode_www_form(params) unless params.empty?
      request = METHODS.fetch(method).new(uri)
      request["Authorization"] = "Bearer #{@token.call}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body
      response = send_request(uri, request, allow_missing: allow_missing)
      return nil if response.nil?
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    end

    def send_request(uri, request, allow_missing: false)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
      status = response.code.to_i
      return nil if allow_missing && status == 404
      raise Error.new(status, response.body) unless status.between?(200, 299)
      response
    end
  end

  class Setup
    # China mainland needs an ICP filing number, which this app does not have.
    EXCLUDED_TERRITORIES = ["CHN"].freeze

    def initialize(client, log: ->(message) { puts(message) })
      @api = client
      @log = log
    end

    def app_id(bundle_id)
      app = @api.get("/v1/apps", "filter[bundleId]" => bundle_id)["data"].first
      raise "No app with bundle ID #{bundle_id} in App Store Connect" unless app
      app["id"]
    end

    # Free app (price tier 0 in the base territory).
    def ensure_free(app)
      prices = @api.get_if_exists("/v1/appPriceSchedules/#{app}/manualPrices")
      return @log.call("App price: already set, unchanged") if prices && !prices["data"].empty?

      point = @api.find("/v1/apps/#{app}/appPricePoints", "filter[territory]" => "DEU", "limit" => 200) do |item|
        item.dig("attributes", "customerPrice").to_f.zero?
      end
      raise "No free price point for Germany" unless point

      @api.post("/v1/appPriceSchedules", {
        data: {
          type: "appPriceSchedules",
          relationships: {
            app: { data: { type: "apps", id: app } },
            baseTerritory: { data: { type: "territories", id: "DEU" } },
            manualPrices: { data: [{ type: "appPrices", id: "${price}" }] }
          }
        },
        included: [{
          type: "appPrices", id: "${price}", attributes: { startDate: nil },
          relationships: { appPricePoint: { data: { type: "appPricePoints", id: point["id"] } } }
        }]
      })
      @log.call("App price: free")
    end

    def ensure_app_availability(app)
      existing = @api.get_if_exists("/v1/apps/#{app}/appAvailabilityV2")
      return @log.call("App availability: already set, unchanged") if existing && existing["data"]

      included = territories.each_with_index.map do |territory, index|
        { type: "territoryAvailabilities", id: "${t#{index}}", attributes: { available: true },
          relationships: { territory: { data: { type: "territories", id: territory } } } }
      end
      @api.post("/v2/appAvailabilities", {
        data: {
          type: "appAvailabilities",
          attributes: { availableInNewTerritories: true },
          relationships: {
            app: { data: { type: "apps", id: app } },
            territoryAvailabilities: { data: included.map { |entry| { type: entry[:type], id: entry[:id] } } }
          }
        },
        included: included
      })
      @log.call("App availability: #{included.size} territories")
    end

    private

    def territories
      @territories ||= @api.all("/v1/territories", "limit" => 200).map { |item| item["id"] } - EXCLUDED_TERRITORIES
    end
  end
end
