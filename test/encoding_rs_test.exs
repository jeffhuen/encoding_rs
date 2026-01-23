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

  describe "dirty_threshold/0" do
    test "returns threshold value" do
      assert EncodingRs.dirty_threshold() == 64 * 1024
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
end
