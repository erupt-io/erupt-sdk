# frozen_string_literal: true

require "openssl"

module Erupt
  # Erupt-Signature (erupt-cloud/PROTOCOL.md §4.3): an HMAC-SHA256 the server puts on every forward, keyed by
  # the node's access token, so the token need not travel and the signed headers cannot be forged.
  module Signature
    WINDOW_SECONDS = 300
    UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD"

    module_function

    # +body+ is the raw bytes, or nil for a multipart upload the server re-encodes (not covered).
    def sign(access_token, method, path_and_query, timestamp, enforced, user, body)
      canonical = [method.upcase, path_and_query, timestamp.to_s, enforced.to_s, sha256(user.to_s),
                   body.nil? ? UNSIGNED_PAYLOAD : sha256(body)].join("\n")
      OpenSSL::HMAC.hexdigest("SHA256", access_token, canonical)
    end

    def verify(access_token, method, path_and_query, timestamp, enforced, user, body, signature, now)
      ts = Integer(timestamp.to_s.strip, 10, exception: false)
      return false if ts.nil? || (now - ts).abs > WINDOW_SECONDS

      OpenSSL.secure_compare(sign(access_token, method, path_and_query, ts, enforced, user, body), signature.to_s.strip)
    end

    def sha256(data) = OpenSSL::Digest::SHA256.hexdigest(data)
  end
end
