# frozen_string_literal: true

require_relative "test_helper"

class SignatureTest < Minitest::Test
  VECTORS = JSON.parse(File.read(File.expand_path("../../conformance/signature-vectors.json", __dir__)))

  def test_java_vectors
    token = VECTORS["accessToken"]
    VECTORS["vectors"].each do |v|
      args = [token, v["method"], v["pathAndQuery"], v["timestamp"], v["enforced"], v["user"], v["body"]]
      assert_equal v["signature"], Erupt::Signature.sign(*args), v["case"]
      args[3] = v["timestamp"].to_s
      assert Erupt::Signature.verify(*args, v["signature"], v["timestamp"] + 300), v["case"]
      refute Erupt::Signature.verify(*args, v["signature"], v["timestamp"] + 301), "#{v["case"]}: outside the window"
      refute Erupt::Signature.verify(*args, v["signature"].reverse, v["timestamp"]), "#{v["case"]}: wrong signature"
    end
  end

  def test_rejects_an_illegal_timestamp
    refute Erupt::Signature.verify("t", "GET", "/", "soon", nil, nil, "", "00", 0)
    refute Erupt::Signature.verify("t", "GET", "/", nil, nil, nil, "", "00", 0)
  end
end
