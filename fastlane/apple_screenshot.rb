require "digest"
require_relative "home_brief_catalog"

module AppleScreenshot
  def self.attachment(directory, test:, title:)
    manifest = JSON.parse(File.read(File.join(directory, "manifest.json")))
    tests = manifest.select { |row| row["testIdentifier"] == test }
    raise "Expected exactly one matching screenshot test" unless tests.size == 1
    images = tests.first.fetch("attachments").select do |entry|
      entry["deviceName"].to_s.start_with?("iPhone") && entry["isAssociatedWithFailure"] == false &&
        /\A#{Regexp.escape(title)}(?:_\d+_[0-9A-Fa-f-]+)?\.png\z/.match?(entry["suggestedHumanReadableName"].to_s)
    end
    raise "Expected exactly one named iPhone PNG" unless images.size == 1
    name = images.first.fetch("exportedFileName")
    raise "Unexpected exported filename" unless /\A[0-9a-f-]{36}\.png\z/i.match?(name)
    path = File.join(directory, name)
    raise "Expected a regular screenshot file of at most 10 MiB" unless File.file?(path) && !File.symlink?(path) && File.size(path).between?(45, 10 * 1024 * 1024)
    data = File.binread(path)
    raise "Invalid iPhone PNG" unless data.start_with?("\x89PNG\r\n\x1a\n".b) && data.byteslice(12, 4) == "IHDR" &&
      data.byteslice(-8, 4) == "IEND" && data.byteslice(16, 8).unpack("N2").all? { |dim| dim.between?(600, 4000) }
    data
  end


  module Storage
    def upload(operation, bytes)
      url = URI(operation.fetch("url"))
      raise "Unexpected asset upload destination" unless url.scheme == "https" && url.host.to_s.end_with?(".apple.com") &&
        url.port == 443 && url.userinfo.nil? && url.fragment.nil? && operation["method"] == "PUT"
      req = Net::HTTP::Put.new(url.request_uri)
      Array(operation["requestHeaders"]).each do |header|
        name, value = header.values_at("name", "value")
        raise "Unexpected asset upload header" if %w[authorization proxy-authorization host cookie].include?(name.to_s.downcase)
        req[name] = value
      end
      req.body = bytes
      # Presigned Apple storage URLs get only their supplied headers, never the Connect token.
      result = Net::HTTP.start(url.host, url.port, use_ssl: true, open_timeout: 15, read_timeout: 90) { |http| http.request(req) }
      raise "Apple asset upload failed (HTTP #{result.code})" unless result.is_a?(Net::HTTPSuccess)
    rescue URI::Error, IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError
      raise "Apple asset upload connection failed", cause: nil
    end

  end

  def self.transfer(client, path, asset, id, bytes, checksum)
    ops = asset.fetch("attributes").fetch("uploadOperations").sort_by { |op| op.fetch("offset") }
    cursor = 0
    ops.each do |op|
      raise "Invalid upload byte ranges" unless op["offset"] == cursor && op["length"].is_a?(Integer) && op["length"].positive?
      cursor += op["length"]
    end
    raise "Apple upload operations must cover the entire PNG" unless cursor == bytes.bytesize
    ops.each { |op| client.upload(op, bytes.byteslice(op["offset"], op["length"])) }
    client.commit(id, checksum)
    wait_for_processing(client, path, id, checksum)
  end

  def self.wait_for_processing(client, path, id, checksum)
    30.times do
      attrs = client.get("#{path}/#{id}").fetch("data").fetch("attributes")
      state = attrs.fetch("assetDeliveryState").fetch("state")
      if state == "COMPLETE"
        raise "Processed screenshot checksum mismatch" unless attrs["sourceFileChecksum"] == checksum
        return
      end
      raise "Apple did not accept the screenshot (#{state})" unless %w[AWAITING_UPLOAD UPLOAD_COMPLETE].include?(state)
      sleep 2
    end
    raise "Apple is still processing the screenshot. Verify its state before retrying."
  end
end
