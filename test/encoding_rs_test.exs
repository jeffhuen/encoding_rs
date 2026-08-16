defmodule EncodingRsTest do
  use ExUnit.Case
  doctest EncodingRs

  describe "decode/2" do
    test "decodes ISO-8859-1" do
      assert {:ok, "café"} == EncodingRs.decode(<<99, 97, 102, 233>>, "iso-8859-1")
    end

    test "decodes Windows-949 (Korean)" do
      assert {:ok, "Hello, 世界!"} ==
               EncodingRs.decode(
                 <<72, 101, 108, 108, 111, 44, 32, 225, 166, 205, 163, 33>>,
                 "windows-949"
               )
    end

    test "decodes Windows-1251 (Cyrillic)" do
      assert {:ok, "ћирилица"} ==
               EncodingRs.decode(<<158, 232, 240, 232, 235, 232, 246, 224>>, "windows-1251")
    end

    test "replaces invalid bytes with replacement character" do
      assert {:ok, "\u{c6b0}\u{c640}\u{fffd}\u{c559}"} ==
               EncodingRs.decode(<<0xBF, 0xEC, 0xBF, 0xCD, 0xFF, 0xBE, 0xD3>>, "windows-949")

      # Same with alias
      assert {:ok, "\u{c6b0}\u{c640}\u{fffd}\u{c559}"} ==
               EncodingRs.decode(<<0xBF, 0xEC, 0xBF, 0xCD, 0xFF, 0xBE, 0xD3>>, "euc-kr")
    end

    test "returns error for unknown encoding" do
      assert {:error, :unknown_encoding} == EncodingRs.decode(<<1, 2, 3>>, "not-an-encoding")
    end
  end

  describe "decode!/2" do
    test "returns decoded string directly" do
      assert "café" == EncodingRs.decode!(<<99, 97, 102, 233>>, "iso-8859-1")
    end

    test "raises on unknown encoding" do
      assert_raise ArgumentError, ~r/unknown encoding/, fn ->
        EncodingRs.decode!(<<1, 2, 3>>, "not-an-encoding")
      end
    end
  end

  describe "decode_with_details/2" do
    test "reports replacement errors and the encoding selected by a BOM" do
      assert {:ok, "�", "UTF-8", true} ==
               EncodingRs.decode_with_details(<<0xFF>>, "utf-8")

      assert {:ok, "H", "UTF-16LE", false} ==
               EncodingRs.decode_with_details(
                 <<0xFF, 0xFE, 0x48, 0x00>>,
                 "windows-1252"
               )

      assert {:ok, "H"} ==
               EncodingRs.decode(<<0xFF, 0xFE, 0x48, 0x00>>, "windows-1252")
    end
  end

  describe "encode/2" do
    test "encodes to Windows-1251 (Cyrillic)" do
      assert {:ok, <<158, 232, 240, 232, 235, 232, 246, 224>>} ==
               EncodingRs.encode("ћирилица", "windows-1251")
    end

    test "encodes to Windows-1255 (Hebrew)" do
      assert {:ok, <<165, 164, 249>>} == EncodingRs.encode("¥₪ש", "windows-1255")
    end

    test "returns error for unknown encoding" do
      assert {:error, :unknown_encoding} == EncodingRs.encode("hello", "not-an-encoding")
    end

    test "rejects decode-only encodings instead of silently returning UTF-8" do
      for encoding <- ["utf-16le", "utf-16be", "replacement"] do
        assert {:error, :encoder_unavailable} == EncodingRs.encode("hello", encoding)
      end

      assert [{:error, :encoder_unavailable}] ==
               EncodingRs.encode_batch([{"hello", "utf-16le"}])

      assert_raise ArgumentError, ~r/encoding is decode-only/, fn ->
        EncodingRs.encode!("hello", "utf-16le")
      end
    end
  end

  describe "encode!/2" do
    test "returns encoded binary directly" do
      assert <<158, 232, 240, 232, 235, 232, 246, 224>> ==
               EncodingRs.encode!("ћирилица", "windows-1251")
    end

    test "raises on unknown encoding" do
      assert_raise ArgumentError, ~r/unknown encoding/, fn ->
        EncodingRs.encode!("hello", "not-an-encoding")
      end
    end
  end

  describe "encoding_exists?/1" do
    test "returns true for valid encodings" do
      assert EncodingRs.encoding_exists?("utf-8")
      assert EncodingRs.encoding_exists?("UTF-8")
      assert EncodingRs.encoding_exists?("windows-1252")
      assert EncodingRs.encoding_exists?("shift_jis")
    end

    test "returns false for invalid encodings" do
      refute EncodingRs.encoding_exists?("not-an-encoding")
      refute EncodingRs.encoding_exists?("")
    end
  end

  describe "available?/0" do
    test "returns true when the NIF is loaded" do
      assert EncodingRs.available?()
    end
  end

  describe "canonical_name/1" do
    test "returns canonical name for aliases" do
      assert {:ok, "UTF-8"} == EncodingRs.canonical_name("utf-8")
      assert {:ok, "UTF-8"} == EncodingRs.canonical_name("utf8")
      assert {:ok, "windows-1252"} == EncodingRs.canonical_name("latin1")
    end

    test "returns error for invalid encodings" do
      assert {:error, :unknown_encoding} == EncodingRs.canonical_name("not-an-encoding")
    end
  end

  describe "list_encodings/0" do
    test "returns list of encodings" do
      encodings = EncodingRs.list_encodings()
      assert is_list(encodings)
      assert "UTF-8" in encodings
      assert "Shift_JIS" in encodings
      assert "windows-1252" in encodings
    end
  end

  describe "operation options" do
    test "returns defaults and accepts per-call limits" do
      assert EncodingRs.dirty_threshold() == 64 * 1024
      assert EncodingRs.max_input_size() == 100 * 1024 * 1024
      assert EncodingRs.dirty_threshold(dirty_threshold: 0) == 0
      assert EncodingRs.max_input_size(max_input_size: :infinity) == :infinity

      assert {:ok, "hello"} =
               EncodingRs.decode("hello", "utf-8",
                 dirty_threshold: 0,
                 max_input_size: :infinity
               )

      assert {:ok, "hello"} =
               EncodingRs.encode("hello", "utf-8",
                 dirty_threshold: 0,
                 max_input_size: :infinity
               )
    end

    test "rejects invalid options" do
      for opts <- [
            [max_input_size: "100"],
            [max_input_size: -1],
            [max_input_size: :disabled],
            [dirty_threshold: "64"],
            [dirty_threshold: -1]
          ] do
        assert_raise ArgumentError, fn -> EncodingRs.max_input_size(opts) end
      end

      assert_raise ArgumentError, fn ->
        EncodingRs.max_input_size(unknown: true)
      end
    end

    test "keeps application config as a fallback" do
      previous = Application.fetch_env(:encoding_rs, :max_input_size)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:encoding_rs, :max_input_size, value)
          :error -> Application.delete_env(:encoding_rs, :max_input_size)
        end
      end)

      Application.put_env(:encoding_rs, :max_input_size, 4)
      assert {:error, :input_too_large} = EncodingRs.decode("hello", "utf-8")
      assert {:ok, "hello"} = EncodingRs.decode("hello", "utf-8", max_input_size: 5)
    end
  end

  describe "roundtrip" do
    test "encode then decode returns original for UTF-8" do
      original = "Hello, 世界! 🎉"
      {:ok, encoded} = EncodingRs.encode(original, "utf-8")
      {:ok, decoded} = EncodingRs.decode(encoded, "utf-8")
      assert decoded == original
    end

    test "encode then decode for single-byte encodings" do
      # ASCII subset works for all single-byte encodings
      original = "Hello World"

      for encoding <- ["windows-1252", "iso-8859-1", "windows-1251"] do
        {:ok, encoded} = EncodingRs.encode(original, encoding)
        {:ok, decoded} = EncodingRs.decode(encoded, encoding)
        assert decoded == original, "Roundtrip failed for #{encoding}"
      end
    end

    test "encode then decode for Asian encodings" do
      # Japanese text roundtrip through Shift_JIS
      original = "こんにちは"
      {:ok, encoded} = EncodingRs.encode(original, "shift_jis")
      {:ok, decoded} = EncodingRs.decode(encoded, "shift_jis")
      assert decoded == original

      # Korean text roundtrip through EUC-KR
      original_kr = "안녕하세요"
      {:ok, encoded_kr} = EncodingRs.encode(original_kr, "euc-kr")
      {:ok, decoded_kr} = EncodingRs.decode(encoded_kr, "euc-kr")
      assert decoded_kr == original_kr
    end
  end

  describe "detect_bom/1" do
    test "detects UTF-8 BOM" do
      # UTF-8 BOM: EF BB BF
      data = <<0xEF, 0xBB, 0xBF, "hello world">>
      assert {:ok, "UTF-8", 3} = EncodingRs.detect_bom(data)
    end

    test "detects UTF-16LE BOM" do
      # UTF-16LE BOM: FF FE
      data = <<0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00>>
      assert {:ok, "UTF-16LE", 2} = EncodingRs.detect_bom(data)
    end

    test "detects UTF-16BE BOM" do
      # UTF-16BE BOM: FE FF
      data = <<0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69>>
      assert {:ok, "UTF-16BE", 2} = EncodingRs.detect_bom(data)
    end

    test "returns error when no BOM present" do
      assert {:error, :no_bom} = EncodingRs.detect_bom("hello world")
      assert {:error, :no_bom} = EncodingRs.detect_bom(<<0x48, 0x65, 0x6C, 0x6C, 0x6F>>)
    end

    test "returns error for empty binary" do
      assert {:error, :no_bom} = EncodingRs.detect_bom(<<>>)
    end

    test "returns error for partial BOM" do
      # Only first byte of UTF-8 BOM
      assert {:error, :no_bom} = EncodingRs.detect_bom(<<0xEF>>)
      # Only first two bytes of UTF-8 BOM
      assert {:error, :no_bom} = EncodingRs.detect_bom(<<0xEF, 0xBB>>)
    end
  end

  describe "detect_and_strip_bom/1" do
    test "detects and strips UTF-8 BOM" do
      data = <<0xEF, 0xBB, 0xBF, "hello">>
      assert {:ok, "UTF-8", "hello"} = EncodingRs.detect_and_strip_bom(data)
    end

    test "detects and strips UTF-16LE BOM" do
      # "Hi" in UTF-16LE with BOM
      data = <<0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00>>
      assert {:ok, "UTF-16LE", <<0x48, 0x00, 0x69, 0x00>>} = EncodingRs.detect_and_strip_bom(data)
    end

    test "detects and strips UTF-16BE BOM" do
      # "Hi" in UTF-16BE with BOM
      data = <<0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69>>
      assert {:ok, "UTF-16BE", <<0x00, 0x48, 0x00, 0x69>>} = EncodingRs.detect_and_strip_bom(data)
    end

    test "returns error when no BOM present" do
      assert {:error, :no_bom} = EncodingRs.detect_and_strip_bom("hello")
    end

    test "works with BOM-only data" do
      assert {:ok, "UTF-8", ""} = EncodingRs.detect_and_strip_bom(<<0xEF, 0xBB, 0xBF>>)
    end
  end

  describe "decode_batch/1" do
    test "decodes multiple items in single call" do
      items = [
        {<<72, 101, 108, 108, 111>>, "windows-1252"},
        {<<0x82, 0xA0>>, "shift_jis"},
        {<<0xC4, 0xE3, 0xBA, 0xC3>>, "gbk"}
      ]

      results = EncodingRs.decode_batch(items)

      assert [
               {:ok, "Hello"},
               {:ok, "あ"},
               {:ok, "你好"}
             ] = results
    end

    test "handles mixed success and error results" do
      items = [
        {<<72, 101, 108, 108, 111>>, "windows-1252"},
        {<<1, 2, 3>>, "invalid-encoding"},
        {<<0x82, 0xA0>>, "shift_jis"}
      ]

      results = EncodingRs.decode_batch(items)

      assert [
               {:ok, "Hello"},
               {:error, :unknown_encoding},
               {:ok, "あ"}
             ] = results
    end

    test "preserves order of results" do
      items = [
        {<<65>>, "utf-8"},
        {<<66>>, "utf-8"},
        {<<67>>, "utf-8"},
        {<<68>>, "utf-8"}
      ]

      results = EncodingRs.decode_batch(items)

      assert [{:ok, "A"}, {:ok, "B"}, {:ok, "C"}, {:ok, "D"}] = results
    end

    test "handles empty list" do
      assert [] = EncodingRs.decode_batch([])
    end

    test "handles single item" do
      items = [{<<72, 101, 108, 108, 111>>, "utf-8"}]
      assert [{:ok, "Hello"}] = EncodingRs.decode_batch(items)
    end

    test "handles different encodings per item" do
      items = [
        {<<0xC0>>, "windows-1252"},
        {<<0xC0>>, "iso-8859-1"},
        {<<0xC0>>, "windows-1251"}
      ]

      results = EncodingRs.decode_batch(items)

      # Same byte decodes differently in each encoding
      assert [{:ok, "À"}, {:ok, "À"}, {:ok, "А"}] = results
    end
  end

  describe "encode_batch/1" do
    test "encodes multiple items in single call" do
      items = [
        {"Hello", "windows-1252"},
        {"あ", "shift_jis"},
        {"你好", "gbk"}
      ]

      results = EncodingRs.encode_batch(items)

      assert [
               {:ok, "Hello"},
               {:ok, <<130, 160>>},
               {:ok, <<196, 227, 186, 195>>}
             ] = results
    end

    test "handles mixed success and error results" do
      items = [
        {"Hello", "windows-1252"},
        {"test", "invalid-encoding"},
        {"あ", "shift_jis"}
      ]

      results = EncodingRs.encode_batch(items)

      assert [
               {:ok, "Hello"},
               {:error, :unknown_encoding},
               {:ok, <<130, 160>>}
             ] = results
    end

    test "preserves order of results" do
      items = [
        {"A", "utf-8"},
        {"B", "utf-8"},
        {"C", "utf-8"},
        {"D", "utf-8"}
      ]

      results = EncodingRs.encode_batch(items)

      assert [{:ok, "A"}, {:ok, "B"}, {:ok, "C"}, {:ok, "D"}] = results
    end

    test "handles empty list" do
      assert [] = EncodingRs.encode_batch([])
    end

    test "handles single item" do
      items = [{"Hello", "utf-8"}]
      assert [{:ok, "Hello"}] = EncodingRs.encode_batch(items)
    end
  end

  describe "batch roundtrip" do
    test "batch operations honor the aggregate dirty threshold" do
      decode_items = [{"a", "utf-8"}, {"b", "utf-8"}, {"c", "utf-8"}]
      encode_items = [{"a", "windows-1252"}, {"b", "windows-1252"}]

      for dirty_threshold <- [0, 1024] do
        opts = [dirty_threshold: dirty_threshold]

        assert [{:ok, "a"}, {:ok, "b"}, {:ok, "c"}] =
                 EncodingRs.decode_batch(decode_items, opts)

        assert [
                 {:ok, "a", "UTF-8", false},
                 {:ok, "b", "UTF-8", false},
                 {:ok, "c", "UTF-8", false}
               ] = EncodingRs.decode_batch_with_details(decode_items, opts)

        assert [{:ok, "a"}, {:ok, "b"}] = EncodingRs.encode_batch(encode_items, opts)
      end
    end

    test "encode_batch then decode_batch returns original" do
      original_strings = ["Hello", "World", "こんにちは", "你好"]
      encoding = "utf-8"

      encode_items = Enum.map(original_strings, &{&1, encoding})
      encode_results = EncodingRs.encode_batch(encode_items)

      decode_items =
        encode_results
        |> Enum.map(fn {:ok, binary} -> {binary, encoding} end)

      decode_results = EncodingRs.decode_batch(decode_items)

      decoded_strings = Enum.map(decode_results, fn {:ok, s} -> s end)

      assert decoded_strings == original_strings
    end

    test "batch results match individual calls" do
      items = [
        {<<72, 101, 108, 108, 111>>, "windows-1252"},
        {<<0x82, 0xA0>>, "shift_jis"},
        {<<1, 2, 3>>, "invalid-encoding"}
      ]

      batch_results = EncodingRs.decode_batch(items)

      individual_results =
        Enum.map(items, fn {binary, encoding} ->
          EncodingRs.decode(binary, encoding)
        end)

      assert batch_results == individual_results
    end
  end

  describe "BOM detection integration" do
    test "detect BOM and decode file content" do
      # Simulate a UTF-8 file with BOM
      content = "こんにちは"
      file_data = <<0xEF, 0xBB, 0xBF>> <> content

      # Detect encoding and strip BOM
      {:ok, encoding, data_without_bom} = EncodingRs.detect_and_strip_bom(file_data)

      # Decode using detected encoding
      {:ok, decoded} = EncodingRs.decode(data_without_bom, encoding)

      assert encoding == "UTF-8"
      assert decoded == content
    end

    test "detect BOM and decode UTF-16LE content" do
      # "Hi" in UTF-16LE with BOM
      file_data = <<0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00>>

      {:ok, encoding, data_without_bom} = EncodingRs.detect_and_strip_bom(file_data)
      {:ok, decoded} = EncodingRs.decode(data_without_bom, encoding)

      assert encoding == "UTF-16LE"
      assert decoded == "Hi"
    end
  end

  describe "input size validation" do
    test "one-shot operations reject oversized input" do
      assert {:error, :input_too_large} =
               EncodingRs.decode("hello", "utf-8", max_input_size: 4)

      assert {:error, :input_too_large} =
               EncodingRs.encode("hello", "utf-8", max_input_size: 4)

      assert {:ok, "hello"} =
               EncodingRs.decode("hello", "utf-8", max_input_size: :infinity)
    end

    test "bang operations raise for oversized input" do
      assert_raise ArgumentError, ~r/exceeds maximum size/, fn ->
        EncodingRs.decode!("hello", "utf-8", max_input_size: 4)
      end

      assert_raise ArgumentError, ~r/exceeds maximum size/, fn ->
        EncodingRs.encode!("hello", "utf-8", max_input_size: 4)
      end
    end

    test "batch operations reject oversized items individually" do
      items = [{<<72>>, "utf-8"}, {"too big", "utf-8"}, {<<73>>, "utf-8"}]
      results = EncodingRs.decode_batch(items, max_input_size: 4)
      assert [{:ok, "H"}, {:error, :input_too_large}, {:ok, "I"}] = results

      items = [{"H", "utf-8"}, {"too big", "utf-8"}, {"I", "utf-8"}]
      results = EncodingRs.encode_batch(items, max_input_size: 4)
      assert [{:ok, "H"}, {:error, :input_too_large}, {:ok, "I"}] = results
    end
  end
end
