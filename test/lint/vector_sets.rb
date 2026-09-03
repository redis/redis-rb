# frozen_string_literal: true

module Lint
  module VectorSets
    def test_vadd
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_equal false, r.vadd("foo", [0.1, 1.2, 0.5], "element")
      end
    end

    def test_vadd_with_fp32_blob
      target_version "8.0" do
        blob = [0.1, 1.2, 0.5].pack("e*")
        assert_equal true, r.vadd("foo", blob, "element")
        assert_equal false, r.vadd("foo", blob, "element")
      end
    end

    def test_vadd_with_reduce
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5, 0.8], "element", reduce: 2)
      end
    end

    def test_vadd_with_quantization
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element", quantization: :noquant)
        assert_equal true, r.vadd("bar", [0.1, 1.2, 0.5], "element", quantization: :q8)
        assert_equal true, r.vadd("baz", [0.1, 1.2, 0.5], "element", quantization: :bin)
      end
    end

    def test_vadd_with_unknown_quantization
      assert_raises(ArgumentError) do
        r.vadd("foo", [0.1, 1.2, 0.5], "element", quantization: :int4)
      end
    end

    def test_vadd_with_cas_ef_and_m
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element", cas: true, ef: 300, m: 32)
      end
    end

    def test_vcard
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element-1")
        assert_equal 1, r.vcard("foo")
        assert_equal true, r.vadd("foo", [0.3, 0.4, 0.5], "element-2")
        assert_equal 2, r.vcard("foo")
      end
    end

    def test_vcard_with_missing_key
      target_version "8.0" do
        assert_equal 0, r.vcard("missing")
      end
    end

    def test_vdim
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_equal 3, r.vdim("foo")
      end
    end

    def test_vdim_with_reduce
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5, 0.8], "element", reduce: 2)
        assert_equal 2, r.vdim("foo")
      end
    end

    def test_vdim_with_missing_key
      target_version "8.0" do
        assert_raises(Redis::CommandError) { r.vdim("missing") }
      end
    end

    def test_vemb
      target_version "8.0" do
        values = [0.1, 1.2, 0.5]
        assert_equal true, r.vadd("foo", values, "element")

        vector = r.vemb("foo", "element")
        assert_equal 3, vector.size
        vector.zip(values) do |actual, expected|
          assert_kind_of Float, actual
          assert_in_delta expected, actual, 0.05
        end
      end
    end

    def test_vemb_with_noquant
      target_version "8.0" do
        values = [0.1, 1.2, 0.5]
        assert_equal true, r.vadd("foo", values, "element", quantization: :noquant)

        vector = r.vemb("foo", "element")
        vector.zip(values) do |actual, expected|
          assert_in_delta expected, actual, 0.001
        end
      end
    end

    def test_vemb_with_missing_element_or_key
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_nil r.vemb("foo", "missing")
        assert_nil r.vemb("missing", "element")
      end
    end

    def test_vemb_raw
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")

        reply = r.vemb("foo", "element", raw: true)
        assert_equal "int8", reply["quantization"]
        assert_kind_of String, reply["raw"]
        assert_kind_of Float, reply["l2"]
        assert_kind_of Float, reply["range"]
      end
    end

    def test_vemb_raw_with_noquant
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element", quantization: :noquant)

        reply = r.vemb("foo", "element", raw: true)
        assert_equal "f32", reply["quantization"]
        refute reply.key?("range")
        # The blob holds the normalized vector as little-endian FP32.
        normalized = reply["raw"].unpack("e*")
        assert_equal 3, normalized.size
        normalized.zip([0.1, 1.2, 0.5]) do |actual, expected|
          assert_in_delta expected / reply["l2"], actual, 0.001
        end
      end
    end

    def test_vgetattr
      target_version "8.0" do
        attributes = { "size" => "large", "price" => 18.99 }
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element", attributes: attributes)
        assert_equal attributes, r.vgetattr("foo", "element")
      end
    end

    def test_vgetattr_raw
      target_version "8.0" do
        attributes = { "size" => "large" }
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element", attributes: attributes)

        reply = r.vgetattr("foo", "element", raw: true)
        assert_kind_of String, reply
        assert_equal attributes, JSON.parse(reply)
      end
    end

    def test_vgetattr_with_no_attributes
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_nil r.vgetattr("foo", "element")
      end
    end

    def test_vgetattr_with_missing_element_or_key
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_nil r.vgetattr("foo", "missing")
        assert_nil r.vgetattr("missing", "element")
      end
    end

    def test_vinfo
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")

        info = r.vinfo("foo")
        assert_kind_of Hash, info
        assert_equal "int8", info["quant-type"]
        assert_equal 3, info["vector-dim"]
        assert_equal 1, info["size"]
      end
    end

    def test_vinfo_with_noquant
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element", quantization: :noquant)
        assert_equal "f32", r.vinfo("foo")["quant-type"]
      end
    end

    def test_vinfo_with_missing_key
      target_version "8.0" do
        assert_nil r.vinfo("missing")
      end
    end

    def test_vismember
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_equal true, r.vismember("foo", "element")
        assert_equal false, r.vismember("foo", "missing")
      end
    end

    def test_vismember_with_missing_key
      target_version "8.0" do
        assert_equal false, r.vismember("missing", "element")
      end
    end

    def test_vlinks
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "elem-1")
        assert_equal true, r.vadd("foo", [0.2, 1.1, 0.4], "elem-2")
        assert_equal true, r.vadd("foo", [0.3, 1.0, 0.3], "elem-3")

        layers = r.vlinks("foo", "elem-1")
        assert_kind_of Array, layers
        layers.each { |layer| assert_kind_of Array, layer }
        # Which layers an element occupies is probabilistic, so assert on the
        # union of neighbors across layers.
        assert_equal %w[elem-2 elem-3], layers.flatten.uniq.sort
      end
    end

    def test_vlinks_with_scores
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "elem-1")
        assert_equal true, r.vadd("foo", [0.2, 1.1, 0.4], "elem-2")
        assert_equal true, r.vadd("foo", [0.3, 1.0, 0.3], "elem-3")

        layers = r.vlinks("foo", "elem-1", with_scores: true)
        layers.each { |layer| assert_kind_of Hash, layer }
        neighbors = layers.reduce({}, :merge)
        assert_equal %w[elem-2 elem-3], neighbors.keys.sort
        neighbors.each_value { |score| assert_kind_of Float, score }
      end
    end

    def test_vlinks_with_missing_element_or_key
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_nil r.vlinks("foo", "missing")
        assert_nil r.vlinks("missing", "element")
      end
    end

    def test_vrandmember
      target_version "8.0" do
        elements = %w[elem-1 elem-2 elem-3]
        elements.each_with_index do |element, i|
          assert_equal true, r.vadd("foo", [i, 1.0, 0.5], element)
        end

        assert_includes elements, r.vrandmember("foo")
      end
    end

    def test_vrandmember_with_positive_count
      target_version "8.0" do
        elements = %w[elem-1 elem-2 elem-3]
        elements.each_with_index do |element, i|
          assert_equal true, r.vadd("foo", [i, 1.0, 0.5], element)
        end

        sample = r.vrandmember("foo", 2)
        assert_equal 2, sample.size
        assert_equal sample.uniq, sample
        sample.each { |element| assert_includes elements, element }

        # A count larger than the set returns the whole set.
        assert_equal elements, r.vrandmember("foo", 10).sort
      end
    end

    def test_vrandmember_with_negative_count
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")

        sample = r.vrandmember("foo", -5)
        assert_equal ["element"] * 5, sample
      end
    end

    def test_vrandmember_with_missing_key
      target_version "8.0" do
        assert_nil r.vrandmember("missing")
        assert_equal [], r.vrandmember("missing", 3)
      end
    end

    def test_vrange
      target_version "8.4" do
        %w[elem-1 elem-2 elem-3].each_with_index do |element, i|
          assert_equal true, r.vadd("foo", [i, 1.0, 0.5], element)
        end

        assert_equal %w[elem-1 elem-2 elem-3], r.vrange("foo", "-", "+")
        assert_equal %w[elem-1 elem-2 elem-3], r.vrange("foo", "-", "+", -1)
      end
    end

    def test_vrange_with_boundaries
      target_version "8.4" do
        %w[elem-1 elem-2 elem-3].each_with_index do |element, i|
          assert_equal true, r.vadd("foo", [i, 1.0, 0.5], element)
        end

        assert_equal %w[elem-2 elem-3], r.vrange("foo", "[elem-2", "+")
        assert_equal %w[elem-3], r.vrange("foo", "(elem-2", "+")
        assert_equal %w[elem-1 elem-2], r.vrange("foo", "-", "(elem-3")
      end
    end

    def test_vrange_with_count_iteration
      target_version "8.4" do
        %w[elem-1 elem-2 elem-3].each_with_index do |element, i|
          assert_equal true, r.vadd("foo", [i, 1.0, 0.5], element)
        end

        page = r.vrange("foo", "-", "+", 2)
        assert_equal %w[elem-1 elem-2], page
        assert_equal %w[elem-3], r.vrange("foo", "(#{page.last}", "+", 2)
      end
    end

    def test_vrange_with_missing_key
      target_version "8.4" do
        assert_equal [], r.vrange("missing", "-", "+")
      end
    end

    def test_vrem
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "elem-1")
        assert_equal true, r.vadd("foo", [0.2, 1.1, 0.4], "elem-2")

        assert_equal true, r.vrem("foo", "elem-1")
        assert_equal false, r.vismember("foo", "elem-1")
        assert_equal 1, r.vcard("foo")
        assert_equal false, r.vrem("foo", "elem-1")
      end
    end

    def test_vrem_with_missing_element_or_key
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_equal false, r.vrem("foo", "missing")
        assert_equal false, r.vrem("missing", "element")
      end
    end

    def test_vrem_last_element_deletes_the_key
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_equal true, r.vrem("foo", "element")
        assert_equal 0, r.vcard("foo")
        assert_equal false, r.exists?("foo")
      end
    end

    def test_vsetattr
      target_version "8.0" do
        attributes = { "type" => "fruit", "color" => "red" }
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_equal true, r.vsetattr("foo", "element", attributes)
        assert_equal attributes, r.vgetattr("foo", "element")
      end
    end

    def test_vsetattr_overwrites_existing_attributes
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element", attributes: { "size" => "large" })
        assert_equal true, r.vsetattr("foo", "element", { "size" => "small" })
        assert_equal({ "size" => "small" }, r.vgetattr("foo", "element"))
      end
    end

    def test_vsetattr_with_json_string
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_equal true, r.vsetattr("foo", "element", '{"size": "large"}')
        assert_equal({ "size" => "large" }, r.vgetattr("foo", "element"))
      end
    end

    def test_vsetattr_deletes_attributes
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element", attributes: { "size" => "large" })
        assert_equal true, r.vsetattr("foo", "element", nil)
        assert_nil r.vgetattr("foo", "element")

        assert_equal true, r.vsetattr("foo", "element", { "size" => "small" })
        assert_equal true, r.vsetattr("foo", "element", "")
        assert_nil r.vgetattr("foo", "element")
      end
    end

    def test_vsetattr_with_missing_element_or_key
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element")
        assert_equal false, r.vsetattr("foo", "missing", { "a" => 1 })
        assert_equal false, r.vsetattr("missing", "element", { "a" => 1 })
      end
    end

    def test_vsim
      target_version "8.0" do
        add_vsim_fixture
        assert_equal %w[a b c], r.vsim("foo", element: "a")
        assert_equal %w[a b c], r.vsim("foo", vector: [1.0, 0.0, 0.0])
        assert_equal %w[a b c], r.vsim("foo", vector: [1.0, 0.0, 0.0].pack("e*"))
      end
    end

    def test_vsim_with_scores
      target_version "8.0" do
        add_vsim_fixture

        scores = r.vsim("foo", element: "a", with_scores: true)
        assert_equal %w[a b c], scores.keys
        assert_in_delta 1.0, scores["a"], 0.001
        scores.each_value { |score| assert_kind_of Float, score }
      end
    end

    def test_vsim_with_scores_and_attribs
      target_version "8.0.3" do
        add_vsim_fixture

        results = r.vsim("foo", element: "a", with_scores: true, with_attribs: true)
        assert_equal %w[a b c], results.keys
        score, attribs = results["a"]
        assert_in_delta 1.0, score, 0.001
        assert_equal({ "n" => 1 }, attribs)
        assert_nil results["b"][1]

        raw_results = r.vsim("foo", element: "a", with_scores: true, with_attribs: true, raw: true)
        assert_equal({ "n" => 1 }, JSON.parse(raw_results["a"][1]))
        assert_nil raw_results["b"][1]
      end
    end

    def test_vsim_with_attribs
      target_version "8.0.3" do
        add_vsim_fixture

        results = r.vsim("foo", element: "a", with_attribs: true)
        assert_equal({ "n" => 1 }, results["a"])
        assert_nil results["b"]
        assert_equal({ "n" => 3 }, results["c"])

        raw_results = r.vsim("foo", element: "a", with_attribs: true, raw: true)
        assert_equal({ "n" => 1 }, JSON.parse(raw_results["a"]))
        assert_nil raw_results["b"]
      end
    end

    def test_vsim_with_options
      target_version "8.0" do
        add_vsim_fixture
        assert_equal %w[a b], r.vsim("foo", element: "a", count: 2)
        assert_equal %w[a b c], r.vsim("foo", element: "a", truth: true, nothread: true, ef: 300)
        # Only elements closer than the epsilon distance qualify.
        assert_equal %w[a b], r.vsim("foo", element: "a", epsilon: 0.4)
      end
    end

    def test_vsim_with_filter
      target_version "8.0" do
        add_vsim_fixture
        assert_equal %w[c], r.vsim("foo", element: "a", filter: ".n == 3")
        assert_equal %w[a c], r.vsim("foo", element: "a", filter: ".n >= 1", filter_ef: 100)
      end
    end

    def test_vsim_requires_exactly_one_query_form
      assert_raises(ArgumentError) { r.vsim("foo") }
      assert_raises(ArgumentError) { r.vsim("foo", vector: [1.0], element: "a") }
    end

    def test_vsim_with_missing_key
      target_version "8.0" do
        assert_equal [], r.vsim("missing", vector: [1.0, 0.0, 0.0])
        assert_equal({}, r.vsim("missing", vector: [1.0, 0.0, 0.0], with_scores: true))
      end
    end

    def add_vsim_fixture
      assert_equal true, r.vadd("foo", [1.0, 0.0, 0.0], "a", attributes: { "n" => 1 })
      assert_equal true, r.vadd("foo", [0.9, 0.1, 0.0], "b")
      assert_equal true, r.vadd("foo", [0.0, 1.0, 0.0], "c", attributes: { "n" => 3 })
    end

    def test_vadd_with_attributes
      target_version "8.0" do
        assert_equal true, r.vadd("foo", [0.1, 1.2, 0.5], "element", attributes: { "size" => "large" })
        assert_equal true, r.vadd("bar", [0.1, 1.2, 0.5], "element", attributes: '{"size": "small"}')
      end
    end
  end
end
