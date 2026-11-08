require "digest"
require "json"
require "net/http"
require "uri"

# The parts of App Store Connect that fastlane does not cover: the app's price and availability and the
# in-app purchase with its texts, price, availability and review screenshot. Every step first looks at what
# is there and only creates what is missing, so the lane can run again and again; prices and territories
# that already exist are never touched (change them in App Store Connect).
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

    def delete(path)
      request(:delete, path)
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

    # Sends bytes as one of the upload operations App Store Connect hands out (no API token there).
    def upload(operation, bytes)
      uri = URI(operation["url"])
      request = METHODS.fetch(operation["method"].downcase.to_sym).new(uri)
      (operation["requestHeaders"] || []).each { |header| request[header["name"]] = header["value"] }
      request.body = bytes.byteslice(operation["offset"], operation["length"])
      send_request(uri, request)
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
    INCOMPLETE_UPLOADS = ["AWAITING_UPLOAD", "FAILED"].freeze

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

    # Non-consumable, Family Sharing on. Returns its ID.
    def ensure_in_app_purchase(app, product_id:, name:, review_note:)
      existing = @api.get("/v1/apps/#{app}/inAppPurchasesV2", "filter[productId]" => product_id)["data"].first
      if existing
        attributes = existing["attributes"]
        unless attributes["familySharable"] && attributes["reviewNote"] == review_note
          @api.patch("/v2/inAppPurchases/#{existing['id']}", {
            data: { type: "inAppPurchases", id: existing["id"],
                    attributes: { familySharable: true, reviewNote: review_note } }
          })
        end
        @log.call("In-app purchase #{product_id}: exists (#{attributes['state']})")
        return existing["id"]
      end

      created = @api.post("/v2/inAppPurchases", {
        data: {
          type: "inAppPurchases",
          attributes: { name: name, productId: product_id, inAppPurchaseType: "NON_CONSUMABLE",
                        reviewNote: review_note, familySharable: true },
          relationships: { app: { data: { type: "apps", id: app } } }
        }
      })
      @log.call("In-app purchase #{product_id}: created")
      created["data"]["id"]
    end

    # `texts`: locale => [name, description]
    def ensure_localizations(iap, texts)
      existing = @api.all("/v2/inAppPurchases/#{iap}/inAppPurchaseLocalizations", "limit" => 50)
      texts.each do |locale, (name, description)|
        current = existing.find { |item| item.dig("attributes", "locale") == locale }
        attributes = { name: name, description: description }
        if current.nil?
          @api.post("/v1/inAppPurchaseLocalizations", {
            data: { type: "inAppPurchaseLocalizations", attributes: attributes.merge(locale: locale),
                    relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap } } } }
          })
        elsif current.dig("attributes", "name") != name || current.dig("attributes", "description") != description
          @api.patch("/v1/inAppPurchaseLocalizations/#{current['id']}", {
            data: { type: "inAppPurchaseLocalizations", id: current["id"], attributes: attributes }
          })
        end
      end
      @log.call("In-app purchase texts: #{texts.keys.join(', ')}")
    end

    # `price` as App Store Connect writes it for Germany, e.g. "6.99".
    def ensure_iap_price(iap, price)
      prices = @api.get_if_exists("/v1/inAppPurchasePriceSchedules/#{iap}/manualPrices")
      return @log.call("In-app purchase price: already set, unchanged") if prices && !prices["data"].empty?

      point = @api.find("/v2/inAppPurchases/#{iap}/pricePoints", "filter[territory]" => "DEU", "limit" => 200) do |item|
        item.dig("attributes", "customerPrice").to_f == price.to_f
      end
      raise "No price point #{price} € for Germany" unless point

      @api.post("/v1/inAppPurchasePriceSchedules", {
        data: {
          type: "inAppPurchasePriceSchedules",
          relationships: {
            inAppPurchase: { data: { type: "inAppPurchases", id: iap } },
            baseTerritory: { data: { type: "territories", id: "DEU" } },
            manualPrices: { data: [{ type: "inAppPurchasePrices", id: "${price}" }] }
          }
        },
        included: [{
          type: "inAppPurchasePrices", id: "${price}", attributes: { startDate: nil },
          relationships: {
            inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap } },
            inAppPurchasePricePoint: { data: { type: "inAppPurchasePricePoints", id: point["id"] } }
          }
        }]
      })
      @log.call("In-app purchase price: #{price} € (Germany as base, other countries follow)")
    end

    def ensure_iap_availability(iap)
      existing = @api.get_if_exists("/v2/inAppPurchases/#{iap}/inAppPurchaseAvailability")
      return @log.call("In-app purchase availability: already set, unchanged") if existing && existing["data"]

      list = territories
      @api.post("/v1/inAppPurchaseAvailabilities", {
        data: {
          type: "inAppPurchaseAvailabilities",
          attributes: { availableInNewTerritories: true },
          relationships: {
            inAppPurchase: { data: { type: "inAppPurchases", id: iap } },
            availableTerritories: { data: list.map { |territory| { type: "territories", id: territory } } }
          }
        }
      })
      @log.call("In-app purchase availability: #{list.size} territories")
    end

    def ensure_review_screenshot(iap, path)
      current = @api.get_if_exists("/v2/inAppPurchases/#{iap}/appStoreReviewScreenshot")&.dig("data")
      state = current&.dig("attributes", "assetDeliveryState", "state")
      unfinished = INCOMPLETE_UPLOADS.include?(state)
      return @log.call("Review screenshot: already uploaded, unchanged") if current && !unfinished
      return @log.call("Review screenshot: none given, skipped") if path.to_s.empty? || !File.exist?(path)

      # A run that died between reserving and committing leaves a reservation behind; its upload URLs may have
      # expired, so start over instead of reusing it.
      if unfinished
        @api.delete("/v1/inAppPurchaseAppStoreReviewScreenshots/#{current['id']}")
        @log.call("Review screenshot: removed unfinished upload (#{state})")
      end

      bytes = File.binread(path)
      reservation = @api.post("/v1/inAppPurchaseAppStoreReviewScreenshots", {
        data: {
          type: "inAppPurchaseAppStoreReviewScreenshots",
          attributes: { fileName: File.basename(path), fileSize: bytes.bytesize },
          relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap } } }
        }
      })["data"]
      reservation.dig("attributes", "uploadOperations").each { |operation| @api.upload(operation, bytes) }
      @api.patch("/v1/inAppPurchaseAppStoreReviewScreenshots/#{reservation['id']}", {
        data: { type: "inAppPurchaseAppStoreReviewScreenshots", id: reservation["id"],
                attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(bytes) } }
      })
      @log.call("Review screenshot: uploaded #{File.basename(path)}")
    end

    private

    def territories
      @territories ||= @api.all("/v1/territories", "limit" => 200).map { |item| item["id"] } - EXCLUDED_TERRITORIES
    end
  end
end
