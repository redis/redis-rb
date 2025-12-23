# frozen_string_literal: true

require "helper"
require "json"

# Tests for Redis Vector Set commands
# Ported from redis-py: tests/test_vsets.py
class TestCommandsOnVectorSet < Minitest::Test
  include Helper::Client

  def setup
    super

    # Check if Vector Set commands are available (Redis 8.0+)
    begin
      r.call('VCARD', '__test__')
    rescue Redis::CommandError => e
      if e.message.include?("unknown command") || e.message.include?("ERR unknown")
        skip "Vector Set commands not available (requires Redis 8.0+): #{e.message}"
      end
    end

    r.flushdb
  end

  def redis_version
    @redis_version ||= begin
      info = r.info("server")
      version_str = info["redis_version"]
      parts = version_str.split('.')
      parts[0].to_i * 1_000_000 + parts[1].to_i * 1000 + parts[2].to_i
    end
  end

  def skip_if_redis_version_lt(min_version_str)
    parts = min_version_str.split('.')
    min_version = parts[0].to_i * 1_000_000 + parts[1].to_i * 1000 + parts[2].to_i
    skip "Redis version #{min_version_str}+ required" if redis_version < min_version
  end

  # Helper method to convert float array to FP32 blob (little-endian)
  def to_fp32_blob(float_array)
    float_array.pack("e*")
  end

  # Helper method to validate quantization with tolerance
  def validate_quantization(original, quantized, tolerance: 0.1)
    return false if original.length != quantized.length

    max_diff = original.zip(quantized).map { |o, q| (o - q).abs }.max
    max_diff <= tolerance
  end

  # Test: Add element with VALUES format
  def test_add_elem_with_values
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 0.11]
    resp = r.vadd("myset", float_array, "elem1")
    assert_equal 1, resp

    emb = r.vemb("myset", "elem1")
    assert validate_quantization(float_array, emb, tolerance: 0.1)

    # Test invalid data
    assert_raises(ArgumentError) do
      r.vadd("myset_invalid", nil, "elem1")
    end
  end

  # Test: Add element with FP32 blob format
  def test_add_elem_with_vector
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 0.11]
    byte_array = to_fp32_blob(float_array)
    resp = r.vadd("myset", byte_array, "elem1")
    assert_equal 1, resp

    emb = r.vemb("myset", "elem1")
    assert validate_quantization(float_array, emb, tolerance: 0.1)
  end

  # Test: Add element with reduced dimensions
  def test_add_elem_reduced_dim
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 0.11, 0.5, 0.9]
    resp = r.vadd("myset", float_array, "elem1", reduce_dim: 3)
    assert_equal 1, resp

    dim = r.vdim("myset")
    assert_equal 3, dim
  end

  # Test: Add element with CAS option
  def test_add_elem_cas
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 0.11, 0.5, 0.9]
    resp = r.vadd("myset", float_array, "elem1", cas: true)
    assert_equal 1, resp

    emb = r.vemb("myset", "elem1")
    assert validate_quantization(float_array, emb, tolerance: 0.1)
  end

  # Test: Add element with NOQUANT quantization
  def test_add_elem_no_quant
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 0.11, 0.5, 0.9]
    resp = r.vadd("myset", float_array, "elem1", quantization: "NOQUANT")
    assert_equal 1, resp

    emb = r.vemb("myset", "elem1")
    # Use small tolerance for FP32 precision differences
    assert validate_quantization(float_array, emb, tolerance: 0.0001)
  end

  # Test: Add element with BIN quantization
  def test_add_elem_bin_quant
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 0.0, 0.05, -2.9]
    resp = r.vadd("myset", float_array, "elem1", quantization: "BIN")
    assert_equal 1, resp

    emb = r.vemb("myset", "elem1")
    expected_array = [1.0, 1.0, -1.0, 1.0, -1.0]
    assert validate_quantization(expected_array, emb, tolerance: 0.0)
  end

  # Test: Add element with Q8 quantization
  def test_add_elem_q8_quant
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 10.0, -21.0, -2.9]
    resp = r.vadd("myset", float_array, "elem1", quantization: "BIN")
    assert_equal 1, resp

    emb = r.vemb("myset", "elem1")
    expected_array = [1.0, 1.0, 1.0, -1.0, -1.0]
    assert validate_quantization(expected_array, emb, tolerance: 0.0)
  end

  # Test: Add element with EF option
  def test_add_elem_ef
    skip_if_redis_version_lt("7.9.0")

    r.vadd("myset", [5.0, 55.0, 65.0, -20.0, 30.0], "elem1")
    r.vadd("myset", [-40.0, -40.32, 10.0, -4.0, 2.9], "elem2")

    float_array = [1.0, 4.32, 10.0, -21.0, -2.9]
    resp = r.vadd("myset", float_array, "elem3", ef: 1)
    assert_equal 1, resp

    emb = r.vemb("myset", "elem3")
    assert validate_quantization(float_array, emb, tolerance: 0.1)

    sim = r.vsim("myset", "elem3", with_scores: true)
    assert_equal 3, sim.length
  end

  # Test: Add element with attributes
  def test_add_elem_with_attr
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 10.0, -21.0, -2.9]
    attrs_dict = { "key1" => "value1", "key2" => "value2" }
    resp = r.vadd("myset", float_array, "elem3", attributes: attrs_dict)
    assert_equal 1, resp

    emb = r.vemb("myset", "elem3")
    assert validate_quantization(float_array, emb, tolerance: 0.1)

    attr_saved = r.vgetattr("myset", "elem3")
    assert_equal attrs_dict, attr_saved

    # Test with empty attributes
    resp = r.vadd("myset", float_array, "elem4", attributes: {})
    assert_equal 1, resp

    emb = r.vemb("myset", "elem4")
    assert validate_quantization(float_array, emb, tolerance: 0.1)

    attr_saved = r.vgetattr("myset", "elem4")
    assert_nil attr_saved

    # Test with JSON string attributes
    resp = r.vadd("myset", float_array, "elem5", attributes: JSON.generate(attrs_dict))
    assert_equal 1, resp

    emb = r.vemb("myset", "elem5")
    assert validate_quantization(float_array, emb, tolerance: 0.1)

    attr_saved = r.vgetattr("myset", "elem5")
    assert_equal attrs_dict, attr_saved
  end

  # Test: Add element with numlinks
  def test_add_elem_with_numlinks
    skip_if_redis_version_lt("7.9.0")

    elements_count = 100
    vector_dim = 10
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand(0..10).to_f }
      r.vadd("myset", float_array, "elem#{i}", numlinks: 8)
    end

    float_array = [1.0, 4.32, 0.11, 0.5, 0.9, 0.1, 0.2, 0.3, 0.4, 0.5]
    resp = r.vadd("myset", float_array, "elem_numlinks", numlinks: 8)
    assert_equal 1, resp

    emb = r.vemb("myset", "elem_numlinks")
    assert validate_quantization(float_array, emb, tolerance: 0.5)

    numlinks_all_layers = r.vlinks("myset", "elem_numlinks")
    numlinks_all_layers.each do |neighbours_list_for_layer|
      assert neighbours_list_for_layer.length <= 8
    end
  end

  # Test: VSIM with count parameter
  def test_vsim_count
    skip_if_redis_version_lt("7.9.0")

    elements_count = 30
    vector_dim = 800
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand * 10 }
      r.vadd("myset", float_array, "elem#{i}", numlinks: 64)
    end

    vsim = r.vsim("myset", "elem1")
    assert_equal 10, vsim.length
    assert_instance_of Array, vsim
    assert_instance_of String, vsim[0]

    vsim = r.vsim("myset", "elem1", count: 5)
    assert_equal 5, vsim.length
    assert_instance_of Array, vsim
    assert_instance_of String, vsim[0]

    vsim = r.vsim("myset", "elem1", count: 50)
    assert_equal 30, vsim.length
    assert_instance_of Array, vsim
    assert_instance_of String, vsim[0]

    vsim = r.vsim("myset", "elem1", count: 15)
    assert_equal 15, vsim.length
    assert_instance_of Array, vsim
    assert_instance_of String, vsim[0]
  end

  # Test: VSIM with scores
  def test_vsim_with_scores
    skip_if_redis_version_lt("7.9.0")

    elements_count = 20
    vector_dim = 50
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand * 10 }
      r.vadd("myset", float_array, "elem#{i}", numlinks: 64)
    end

    vsim = r.vsim("myset", "elem1", with_scores: true)
    assert_equal 10, vsim.length
    assert_instance_of Hash, vsim
    assert_instance_of Float, vsim["elem1"]
    assert vsim["elem1"] >= 0 && vsim["elem1"] <= 1
  end

  # Test: VSIM with attributes
  def test_vsim_with_attribs_attribs_set
    skip_if_redis_version_lt("8.2.0")

    elements_count = 5
    vector_dim = 10
    attrs_dict = { "key1" => "value1", "key2" => "value2" }
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand * 5 }
      r.vadd("myset", float_array, "elem#{i}", numlinks: 64,
                                               attributes: (i.even? ? attrs_dict : nil))
    end

    vsim = r.vsim("myset", "elem1", with_attribs: true)
    assert_equal 5, vsim.length
    assert_instance_of Hash, vsim
    assert_nil vsim["elem1"]
    assert_equal attrs_dict, vsim["elem2"]
  end

  # Test: VSIM with scores and attributes
  def test_vsim_with_scores_and_attribs_attribs_set
    skip_if_redis_version_lt("8.2.0")

    elements_count = 5
    vector_dim = 10
    attrs_dict = { "key1" => "value1", "key2" => "value2" }
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand * 5 }
      r.vadd("myset", float_array, "elem#{i}", numlinks: 64,
                                               attributes: (i.even? ? attrs_dict : nil))
    end

    vsim = r.vsim("myset", "elem1", with_scores: true, with_attribs: true)
    assert_equal 5, vsim.length
    assert_instance_of Hash, vsim

    # Check structure: {element => {score: ..., attributes: ...}}
    assert vsim["elem1"].key?("score")
    assert vsim["elem1"].key?("attributes")
    assert_nil vsim["elem1"]["attributes"]
    assert_equal attrs_dict, vsim["elem2"]["attributes"]
  end

  # Test: VSIM with attributes when attributes not set
  def test_vsim_with_attribs_attribs_not_set
    skip_if_redis_version_lt("8.2.0")

    elements_count = 20
    vector_dim = 50
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand * 10 }
      r.vadd("myset", float_array, "elem#{i}", numlinks: 64)
    end

    vsim = r.vsim("myset", "elem1", with_attribs: true)
    assert_equal 10, vsim.length
    assert_instance_of Hash, vsim
    assert_nil vsim["elem1"]
  end

  # Test: VSIM with different vector input types
  def test_vsim_with_different_vector_input_types
    skip_if_redis_version_lt("7.9.0")

    elements_count = 10
    vector_dim = 5
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand * 10 }
      attributes = { "index" => i, "elem_name" => "elem_#{i}" }
      r.vadd("myset", float_array, "elem_#{i}", numlinks: 4, attributes: attributes)
    end

    sim = r.vsim("myset", "elem_1")
    assert_equal 10, sim.length
    assert_instance_of Array, sim

    float_array = [1.0, 4.32, 0.0, 0.05, -2.9]
    sim_to_float_array = r.vsim("myset", float_array)
    assert_equal 10, sim_to_float_array.length
    assert_instance_of Array, sim_to_float_array

    fp32_vector = to_fp32_blob(float_array)
    sim_to_fp32_vector = r.vsim("myset", fp32_vector)
    assert_equal 10, sim_to_fp32_vector.length
    assert_instance_of Array, sim_to_fp32_vector
    assert_equal sim_to_float_array, sim_to_fp32_vector

    # Test invalid input
    assert_raises(Redis::CommandError) do
      r.vsim("myset", nil)
    end
  end

  # Test: VSIM with non-existing element
  def test_vsim_unexisting
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 0.11, 0.5, 0.9]
    r.vadd("myset", float_array, "elem1", cas: true)

    assert_raises(Redis::CommandError) do
      r.vsim("myset", "elem_not_existing")
    end

    sim = r.vsim("myset_not_existing", "elem1")
    assert_equal [], sim
  end

  # Test: VSIM with filter
  def test_vsim_with_filter
    skip_if_redis_version_lt("7.9.0")

    elements_count = 50
    vector_dim = 800
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand(10.0..20.0) }
      attributes = { "index" => i, "elem_name" => "elem_#{i}" }
      r.vadd("myset", float_array, "elem_#{i}", numlinks: 4, attributes: attributes)
    end

    float_array = Array.new(vector_dim) { -rand(10.0..20.0) }
    attributes = { "index" => elements_count, "elem_name" => "elem_special" }
    r.vadd("myset", float_array, "elem_special", numlinks: 4, attributes: attributes)

    sim = r.vsim("myset", "elem_1", filter: ".index > 10")
    assert_equal 10, sim.length
    assert_instance_of Array, sim
    sim.each do |elem|
      assert elem.split("_")[1].to_i > 10
    end

    sim = r.vsim("myset", "elem_1",
                 filter: ".index > 10 and .index < 15 and .elem_name in ['elem_12', 'elem_17']")
    assert_equal 1, sim.length
    assert_instance_of Array, sim
    assert_equal "elem_12", sim[0]

    sim = r.vsim("myset", "elem_1",
                 filter: ".index > 25 and .elem_name in ['elem_12', 'elem_17', 'elem_19']",
                 ef: 100)
    assert_equal 0, sim.length
    assert_instance_of Array, sim

    sim = r.vsim("myset", "elem_1",
                 filter: ".index > 28 and .elem_name in ['elem_12', 'elem_17', 'elem_special']",
                 filter_ef: 1)
    assert_equal 0, sim.length, "Expected 0 results, but got #{sim.length} with filter_ef=1"
    assert_instance_of Array, sim

    sim = r.vsim("myset", "elem_1",
                 filter: ".index > 28 and .elem_name in ['elem_12', 'elem_17', 'elem_special']",
                 filter_ef: 500)
    assert_equal 1, sim.length
    assert_instance_of Array, sim
  end

  # Test: VSIM with truth and no_thread options
  def test_vsim_truth_no_thread_enabled
    skip_if_redis_version_lt("7.9.0")

    elements_count = 1000
    vector_dim = 50
    (1..elements_count).each do |i|
      float_array = Array.new(vector_dim) { i * vector_dim }
      r.vadd("myset", float_array, "elem_#{i}")
    end

    r.vadd("myset", Array.new(vector_dim) { -22.0 }, "elem_man_2")

    sim_without_truth = r.vsim("myset", "elem_man_2", with_scores: true, count: 30)
    sim_truth = r.vsim("myset", "elem_man_2", with_scores: true, count: 30, truth: true)

    assert_equal 30, sim_without_truth.length
    assert_equal 30, sim_truth.length

    assert_instance_of Hash, sim_without_truth
    assert_instance_of Hash, sim_truth

    # Compare scores by position (not by element name, as TRUTH may return different elements)
    scores_truth = sim_truth.values
    scores_without_truth = sim_without_truth.values

    found_better_match = false
    scores_truth.zip(scores_without_truth).each do |score_with_truth, score_without_truth|
      if score_with_truth < score_without_truth
        flunk "Score with truth [#{score_with_truth}] < score without truth [#{score_without_truth}]"
      elsif score_with_truth > score_without_truth
        found_better_match = true
      end
    end

    assert found_better_match

    sim_no_thread = r.vsim("myset", "elem_man_2", with_scores: true, no_thread: true)
    assert_equal 10, sim_no_thread.length
    assert_instance_of Hash, sim_no_thread
  end

  # Test: VSIM with epsilon
  def test_vsim_epsilon
    skip_if_redis_version_lt("8.2.0")

    r.vadd("myset", [2.0, 1.0, 1.0], "a")
    r.vadd("myset", [2.0, 0.0, 1.0], "b")
    r.vadd("myset", [2.0, 0.0, 0.0], "c")
    r.vadd("myset", [2.0, 0.0, 2.0], "d")
    r.vadd("myset", [-2.0, -1.0, -1.0], "e")

    res1 = r.vsim("myset", [2.0, 1.0, 1.0])
    assert_equal 5, res1.length

    res2 = r.vsim("myset", [2.0, 1.0, 1.0], epsilon: 0.5)
    assert_equal 4, res2.length
  end

  # Test: VDIM command
  def test_vdim
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 0.11, 0.5, 0.9, 0.1, 0.2]
    r.vadd("myset", float_array, "elem1")

    dim = r.vdim("myset")
    assert_equal float_array.length, dim

    r.vadd("myset_reduced", float_array, "elem1", reduce_dim: 4)
    reduced_dim = r.vdim("myset_reduced")
    assert_equal 4, reduced_dim

    assert_raises(Redis::CommandError) do
      r.vdim("myset_unexisting")
    end
  end

  # Test: VCARD command
  def test_vcard
    skip_if_redis_version_lt("7.9.0")

    n = 20
    n.times do |i|
      float_array = Array.new(7) { rand * 10 }
      r.vadd("myset", float_array, "elem#{i}")
    end

    card = r.vcard("myset")
    assert_equal n, card

    assert_raises(Redis::CommandError) do
      r.vdim("myset_unexisting")
    end
  end

  # Test: VREM command
  def test_vrem
    skip_if_redis_version_lt("7.9.0")

    n = 3
    n.times do |i|
      float_array = Array.new(7) { rand * 10 }
      r.vadd("myset", float_array, "elem#{i}")
    end

    resp = r.vrem("myset", "elem2")
    assert_equal 1, resp

    card = r.vcard("myset")
    assert_equal n - 1, card

    resp = r.vrem("myset", "elem2")
    assert_equal 0, resp

    card = r.vcard("myset")
    assert_equal n - 1, card

    resp = r.vrem("myset_unexisting", "elem1")
    assert_equal 0, resp
  end

  # Test: VEMB with BIN quantization
  def test_vemb_bin_quantization
    skip_if_redis_version_lt("7.9.0")

    e = [1.0, 4.32, 0.0, 0.05, -2.9]
    r.vadd("myset", e, "elem", quantization: "BIN")

    emb_no_quant = r.vemb("myset", "elem")
    assert_equal [1.0, 1.0, -1.0, 1.0, -1.0], emb_no_quant

    emb_no_quant_raw = r.vemb("myset", "elem", raw: true)
    assert_equal "bin", emb_no_quant_raw["quantization"]
    assert_instance_of String, emb_no_quant_raw["raw"]
    assert_instance_of Float, emb_no_quant_raw["l2"]
    refute emb_no_quant_raw.key?("range")
  end

  # Test: VEMB with Q8 quantization
  def test_vemb_q8_quantization
    skip_if_redis_version_lt("7.9.0")

    e = [1.0, 10.32, 0.0, 2.05, -12.5]
    r.vadd("myset", e, "elem", quantization: "Q8")

    emb_q8_quant = r.vemb("myset", "elem")
    assert validate_quantization(e, emb_q8_quant, tolerance: 0.1)

    emb_q8_quant_raw = r.vemb("myset", "elem", raw: true)
    assert_equal "int8", emb_q8_quant_raw["quantization"]
    assert_instance_of String, emb_q8_quant_raw["raw"]
    assert_instance_of Float, emb_q8_quant_raw["l2"]
    assert_instance_of Float, emb_q8_quant_raw["range"]
  end

  # Test: VEMB with NOQUANT
  def test_vemb_no_quantization
    skip_if_redis_version_lt("7.9.0")

    e = [1.0, 10.32, 0.0, 2.05, -12.5]
    r.vadd("myset", e, "elem", quantization: "NOQUANT")

    emb_no_quant = r.vemb("myset", "elem")
    assert validate_quantization(e, emb_no_quant, tolerance: 0.1)

    emb_no_quant_raw = r.vemb("myset", "elem", raw: true)
    assert_equal "f32", emb_no_quant_raw["quantization"]
    assert_instance_of String, emb_no_quant_raw["raw"]
    assert_instance_of Float, emb_no_quant_raw["l2"]
    refute emb_no_quant_raw.key?("range")
  end

  # Test: VEMB with default quantization
  def test_vemb_default_quantization
    skip_if_redis_version_lt("7.9.0")

    e = [1.0, 5.32, 0.0, 0.25, -5.0]
    r.vadd("myset", e, "elem")

    emb_default_quant = r.vemb("myset", "elem")
    assert validate_quantization(e, emb_default_quant, tolerance: 0.1)

    emb_default_quant_raw = r.vemb("myset", "elem", raw: true)
    assert_equal "int8", emb_default_quant_raw["quantization"]
    assert_instance_of String, emb_default_quant_raw["raw"]
    assert_instance_of Float, emb_default_quant_raw["l2"]
    assert_instance_of Float, emb_default_quant_raw["range"]
  end

  # Test: VEMB with FP32 blob input
  def test_vemb_fp32_quantization
    skip_if_redis_version_lt("7.9.0")

    float_array_fp32 = [1.0, 4.32, 0.11]
    byte_array = to_fp32_blob(float_array_fp32)
    r.vadd("myset", byte_array, "elem")

    emb_fp32_quant = r.vemb("myset", "elem")
    assert validate_quantization(float_array_fp32, emb_fp32_quant, tolerance: 0.1)

    emb_fp32_quant_raw = r.vemb("myset", "elem", raw: true)
    assert_equal "int8", emb_fp32_quant_raw["quantization"]
    assert_instance_of String, emb_fp32_quant_raw["raw"]
    assert_instance_of Float, emb_fp32_quant_raw["l2"]
    assert_instance_of Float, emb_fp32_quant_raw["range"]
  end

  # Test: VEMB with non-existing key/element
  def test_vemb_unexisting
    skip_if_redis_version_lt("7.9.0")

    emb_not_existing = r.vemb("not_existing", "elem")
    assert_nil emb_not_existing

    e = [1.0, 5.32, 0.0, 0.25, -5.0]
    r.vadd("myset", e, "elem")
    emb_elem_not_existing = r.vemb("myset", "not_existing")
    assert_nil emb_elem_not_existing
  end

  # Test: VLINKS command
  def test_vlinks
    skip_if_redis_version_lt("7.9.0")

    elements_count = 100
    vector_dim = 800
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand * 10 }
      r.vadd("myset", float_array, "elem#{i}", numlinks: 8)
    end

    element_links_all_layers = r.vlinks("myset", "elem1")
    assert element_links_all_layers.length >= 1
    element_links_all_layers.each do |neighbours_list_for_layer|
      assert_instance_of Array, neighbours_list_for_layer
      neighbours_list_for_layer.each do |neighbour|
        assert_instance_of String, neighbour
      end
    end

    elem_links_all_layers_with_scores = r.vlinks("myset", "elem1", with_scores: true)
    assert elem_links_all_layers_with_scores.length >= 1
    elem_links_all_layers_with_scores.each do |neighbours_dict_for_layer|
      assert_instance_of Hash, neighbours_dict_for_layer
      neighbours_dict_for_layer.each do |neighbour_key, score_value|
        assert_instance_of String, neighbour_key
        assert_instance_of Float, score_value
      end
    end

    float_array = [0.75, 0.25, 0.5, 0.1, 0.9]
    r.vadd("myset_one_elem_only", float_array, "elem1")
    elem_no_neighbours_with_scores = r.vlinks("myset_one_elem_only", "elem1", with_scores: true)
    assert elem_no_neighbours_with_scores.length >= 1
    elem_no_neighbours_with_scores.each do |neighbours_dict_for_layer|
      assert_instance_of Hash, neighbours_dict_for_layer
      assert_equal 0, neighbours_dict_for_layer.length
    end

    # Test non-existing element
    elem_links_unexisting = r.vlinks("myset", "elem_unexisting")
    assert_nil elem_links_unexisting

    # Test non-existing set
    elem_links_set_unexisting = r.vlinks("myset_unexisting", "elem1")
    assert_nil elem_links_set_unexisting
  end

  # Test: VINFO command
  def test_vinfo
    skip_if_redis_version_lt("7.9.0")

    elements_count = 100
    vector_dim = 8
    elements_count.times do |i|
      float_array = Array.new(vector_dim) { rand * 10 }
      r.vadd("myset", float_array, "elem#{i}")
    end

    vset_info = r.vinfo("myset")
    assert_equal "int8", vset_info["quant-type"]
    assert_equal 8, vset_info["vector-dim"]
    assert_equal elements_count, vset_info["size"]
    assert vset_info["max-level"] >= 0
    assert_equal elements_count, vset_info["hnsw-max-node-uid"]

    # Test non-existing set
    unexisting_vset_info = r.vinfo("myset_unexisting")
    assert_nil unexisting_vset_info
  end

  # Test: VSETATTR and VGETATTR commands
  def test_vsetattr_vgetattr
    skip_if_redis_version_lt("7.9.0")

    float_array = [1.0, 4.32, 0.11]
    r.vadd("myset", float_array, "elem1")

    attributes = { "key1" => "value1", "key2" => "value2" }
    resp = r.vsetattr("myset", "elem1", attributes)
    assert_equal 1, resp

    attrs = r.vgetattr("myset", "elem1")
    assert_equal attributes, attrs

    # Test with JSON string
    resp = r.vsetattr("myset", "elem1", JSON.generate(attributes))
    assert_equal 1, resp

    attrs = r.vgetattr("myset", "elem1")
    assert_equal attributes, attrs

    # Test removing attributes (empty hash)
    resp = r.vsetattr("myset", "elem1", {})
    assert_equal 1, resp

    attrs = r.vgetattr("myset", "elem1")
    assert_nil attrs

    # Test non-existing element
    attrs = r.vgetattr("myset", "elem_unexisting")
    assert_nil attrs

    # Test non-existing set
    attrs = r.vgetattr("myset_unexisting", "elem1")
    assert_nil attrs
  end

  # Test: VRANDMEMBER command
  def test_vrandmember
    skip_if_redis_version_lt("7.9.0")

    elements = []
    10.times do |i|
      float_array = Array.new(8) { rand * 10 }
      r.vadd("myset", float_array, "elem#{i}")
      elements << "elem#{i}"
    end

    # Test single random member
    random_member = r.vrandmember("myset")
    assert_instance_of String, random_member
    assert_includes elements, random_member

    # Test multiple random members
    members_list = r.vrandmember("myset", 2)
    assert_equal 2, members_list.length
    members_list.each do |member|
      assert_includes elements, member
    end

    # Test count larger than set size
    members_list = r.vrandmember("myset", 20)
    assert_equal 10, members_list.length

    # Test negative count (allows duplicates)
    members_list = r.vrandmember("myset", -5)
    assert_equal 5, members_list.length

    # Test non-existing set
    random_member = r.vrandmember("myset_unexisting")
    assert_nil random_member
  end

  # Test: Comprehensive test covering all commands
  def test_comprehensive_vset_operations
    skip_if_redis_version_lt("7.9.0")

    # Create a vector set with multiple elements
    elements = ["elem1", "elem2", "elem3"]
    vector_dim = 8
    elements.each_with_index do |elem, _i|
      float_array = Array.new(vector_dim) { rand * 10 }
      r.vadd("myset", float_array, elem)
    end

    # Test vcard
    assert_equal 3, r.vcard("myset")

    # Test vdim
    assert_equal vector_dim, r.vdim("myset")

    # Test vemb
    emb = r.vemb("myset", "elem1")
    assert_equal vector_dim, emb.length

    # Test vsetattr and vgetattr
    attributes = { "key1" => "value1", "key2" => "value2" }
    r.vsetattr("myset", "elem1", attributes)
    attrs = r.vgetattr("myset", "elem1")
    assert_equal attributes, attrs

    # Test vrandmember
    random_member = r.vrandmember("myset")
    assert_includes elements, random_member

    # Test vinfo
    vset_info = r.vinfo("myset")
    assert_equal "int8", vset_info["quant-type"]
    assert_equal vector_dim, vset_info["vector-dim"]
    assert_equal 3, vset_info["size"]

    # Test vrem
    resp = r.vrem("myset", "elem2")
    assert_equal 1, resp
    assert_equal 2, r.vcard("myset")
  end
end
