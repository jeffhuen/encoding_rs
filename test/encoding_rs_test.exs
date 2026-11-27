defmodule EncodingRsTest do
  use ExUnit.Case
  doctest EncodingRs

  describe "decode/2 and decode/3" do
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

    test "replaces invalid bytes with replacement character by default" do
      assert {:ok, "\u{c6b0}\u{c640}\u{fffd}\u{c559}"} ==
               EncodingRs.decode(<<0xBF, 0xEC, 0xBF, 0xCD, 0xFF, 0xBE, 0xD3>>, "windows-949")

      assert {:ok, "\u{c6b0}\u{c640}\u{fffd}\u{c559}"} ==
               EncodingRs.decode(<<0xBF, 0xEC, 0xBF, 0xCD, 0xFF, 0xBE, 0xD3>>, "euc-kr")
    end

    test "returns error for unknown encoding" do
      assert {:error, :unknown_encoding} == EncodingRs.decode(<<1, 2, 3>>, "not-an-encoding")
    end

    test "supports bom: :sniff, :strip, and :preserve modes" do
      utf16le_bom_hi = <<0xFF, 0xFE, 0x48, 0x00>>
      utf8_bom_hi = <<0xEF, 0xBB, 0xBF, "hi">>

      # :sniff overrides requested encoding when BOM is present
      assert {:ok, "H"} == EncodingRs.decode(utf16le_bom_hi, "windows-1252", bom: :sniff)
      assert {:ok, "hi"} == EncodingRs.decode(utf8_bom_hi, "windows-1252", bom: :sniff)

      # :strip removes BOM only when it matches the requested encoding
      assert {:ok, "ÿþH\0"} == EncodingRs.decode(utf16le_bom_hi, "windows-1252", bom: :strip)
      assert {:ok, "hi"} == EncodingRs.decode(utf8_bom_hi, "utf-8", bom: :strip)
      assert {:ok, "H"} == EncodingRs.decode(utf16le_bom_hi, "utf-16le", bom: :strip)

      # :preserve keeps BOM as U+FEFF and never switches encoding
      assert {:ok, "\uFEFFhi"} == EncodingRs.decode(utf8_bom_hi, "utf-8", bom: :preserve)
      assert {:ok, "\uFEFFH"} == EncodingRs.decode(utf16le_bom_hi, "utf-16le", bom: :preserve)
      assert {:ok, "ÿþH\0"} == EncodingRs.decode(utf16le_bom_hi, "windows-1252", bom: :preserve)
    end

    test "supports strict mode with on_error: :error across all BOM modes" do
      assert {:error, :malformed_input} ==
               EncodingRs.decode(<<0xFF>>, "utf-8", on_error: :error)

      assert {:error, :malformed_input} ==
               EncodingRs.decode(<<0x82>>, "shift_jis", on_error: :error)

      assert {:ok, "H"} ==
               EncodingRs.decode(<<0xFF, 0xFE, 0x48, 0x00>>, "windows-1252",
                 bom: :sniff,
                 on_error: :error
               )

      assert {:ok, "hi"} ==
               EncodingRs.decode(<<0xEF, 0xBB, 0xBF, "hi">>, "utf-8",
                 bom: :strip,
                 on_error: :error
               )

      assert {:ok, "\uFEFFhi"} ==
               EncodingRs.decode(<<0xEF, 0xBB, 0xBF, "hi">>, "utf-8",
                 bom: :preserve,
                 on_error: :error
               )

      assert {:error, :malformed_input} ==
               EncodingRs.decode(<<0xEF, 0xBB, 0xBF, 0xFF>>, "utf-8",
                 bom: :strip,
                 on_error: :error
               )
    end
  end

  describe "decode!/2 and decode!/3" do
    test "returns decoded string directly" do
      assert "café" == EncodingRs.decode!(<<99, 97, 102, 233>>, "iso-8859-1")
    end

    test "raises on unknown encoding or strict malformed input" do
      assert_raise ArgumentError, ~r/unknown encoding/, fn ->
        EncodingRs.decode!(<<1, 2, 3>>, "not-an-encoding")
      end

      assert_raise ArgumentError, ~r/malformed byte sequence/, fn ->
        EncodingRs.decode!(<<0xFF>>, "utf-8", on_error: :error)
      end
    end
  end

  describe "decode_with_details/2 and decode_with_details/3" do
    test "reports replacement errors and the encoding selected by a BOM" do
      assert {:ok, "\uFFFD", "UTF-8", true} ==
               EncodingRs.decode_with_details(<<0xFF>>, "utf-8")

      assert {:ok, "H", "UTF-16LE", false} ==
               EncodingRs.decode_with_details(
                 <<0xFF, 0xFE, 0x48, 0x00>>,
                 "windows-1252"
               )

      assert {:ok, "ÿþH\0", "windows-1252", false} ==
               EncodingRs.decode_with_details(
                 <<0xFF, 0xFE, 0x48, 0x00>>,
                 "windows-1252",
                 bom: :strip
               )

      assert {:error, :malformed_input} ==
               EncodingRs.decode_with_details(<<0xFF>>, "utf-8", on_error: :error)
    end
  end

  describe "encode/2 and encode/3" do
    test "encodes to Windows-1251 (Cyrillic)" do
      assert {:ok, <<158, 232, 240, 232, 235, 232, 246, 224>>} ==
               EncodingRs.encode("ћирилица", "windows-1251")
    end

    test "encodes to Windows-1255 (Hebrew)" do
      assert {:ok, <<165, 164, 249>>} == EncodingRs.encode("¥₪ש", "windows-1255")
    end

    test "replaces unmappable characters with HTML numeric references by default" do
      assert {:ok, "&#127881;"} == EncodingRs.encode("🎉", "windows-1252")
    end

    test "rejects unmappable characters in strict mode" do
      assert {:error, :unmappable_character} ==
               EncodingRs.encode("🎉", "windows-1252", on_error: :error)

      assert {:ok, "Hello"} ==
               EncodingRs.encode("Hello", "windows-1252", on_error: :error)

      assert {:ok, "Hello 🎉"} ==
               EncodingRs.encode("Hello 🎉", "utf-8", on_error: :error)
    end

    test "returns {:error, :invalid_utf8} for invalid UTF-8 input" do
      assert {:error, :invalid_utf8} == EncodingRs.encode(<<0xFF>>, "windows-1252")
      assert {:error, :invalid_utf8} == EncodingRs.encode(<<0xC3, 0x28>>, "utf-8")

      assert {:error, :invalid_utf8} ==
               EncodingRs.encode(<<0xFF>>, "windows-1252", on_error: :error)
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

  describe "encode_with_details/2 and encode_with_details/3" do
    test "reports whether unmappable characters were replaced" do
      assert {:ok, "Hello", false} == EncodingRs.encode_with_details("Hello", "windows-1252")
      assert {:ok, "&#127881;", true} == EncodingRs.encode_with_details("🎉", "windows-1252")

      assert {:error, :unmappable_character} ==
               EncodingRs.encode_with_details("🎉", "windows-1252", on_error: :error)

      assert {:error, :invalid_utf8} ==
               EncodingRs.encode_with_details(<<0xFF>>, "windows-1252")

      assert {:error, :encoder_unavailable} ==
               EncodingRs.encode_with_details("hello", "utf-16le")

      assert {:error, :input_too_large} ==
               EncodingRs.encode_with_details("hello", "utf-8", max_input_size: 4)
    end
  end

  describe "encode!/2 and encode!/3" do
    test "returns encoded binary directly" do
      assert <<158, 232, 240, 232, 235, 232, 246, 224>> ==
               EncodingRs.encode!("ћирилица", "windows-1251")
    end

    test "raises ArgumentError for unknown encoding, invalid UTF-8, or strict unmappable" do
      assert_raise ArgumentError, ~r/unknown encoding/, fn ->
        EncodingRs.encode!("hello", "not-an-encoding")
      end

      assert_raise ArgumentError, ~r/not valid UTF-8/, fn ->
        EncodingRs.encode!(<<0xFF>>, "windows-1252")
      end

      assert_raise ArgumentError, ~r/unmappable character/, fn ->
        EncodingRs.encode!("🎉", "windows-1252", on_error: :error)
      end
    end
  end

  describe "encoding inspection helpers" do
    test "encoding_exists?/1 checks decoding labels" do
      assert EncodingRs.encoding_exists?("utf-8")
      assert EncodingRs.encoding_exists?("UTF-8")
      assert EncodingRs.encoding_exists?("utf-16le")
      assert EncodingRs.encoding_exists?("replacement")
      refute EncodingRs.encoding_exists?("not-an-encoding")
      refute EncodingRs.encoding_exists?("")
    end

    test "can_encode?/1 checks output-capable labels" do
      assert EncodingRs.can_encode?("utf-8")
      assert EncodingRs.can_encode?("shift_jis")
      assert EncodingRs.can_encode?("latin1")
      refute EncodingRs.can_encode?("utf-16le")
      refute EncodingRs.can_encode?("utf-16be")
      refute EncodingRs.can_encode?("replacement")
      refute EncodingRs.can_encode?("not-an-encoding")
    end

    test "canonical_name/1 and output_encoding/1 return WHATWG names" do
      assert {:ok, "UTF-8"} == EncodingRs.canonical_name("utf8")
      assert {:ok, "windows-1252"} == EncodingRs.canonical_name("latin1")
      assert {:error, :unknown_encoding} == EncodingRs.canonical_name("not-an-encoding")

      assert {:ok, "windows-1252"} == EncodingRs.output_encoding("latin1")
      assert {:ok, "UTF-8"} == EncodingRs.output_encoding("utf-16le")
      assert {:ok, "UTF-8"} == EncodingRs.output_encoding("utf-16be")
      assert {:ok, "UTF-8"} == EncodingRs.output_encoding("replacement")
      assert {:error, :unknown_encoding} == EncodingRs.output_encoding("not-an-encoding")
    end

    test "list_encodings/0 and list_output_encodings/0 match WHATWG counts" do
      all = EncodingRs.list_encodings()
      outputs = EncodingRs.list_output_encodings()

      assert length(all) == 40
      assert length(outputs) == 37
      assert "UTF-16LE" in all
      refute "UTF-16LE" in outputs
      refute "UTF-16BE" in outputs
      refute "replacement" in outputs
      assert Enum.all?(outputs, &EncodingRs.can_encode?/1)
    end

    test "available?/0 returns true when the NIF is loaded" do
      assert EncodingRs.available?()
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

    test "rejects invalid options across decode, encode, and detect" do
      for opts <- [
            [max_input_size: "100"],
            [max_input_size: -1],
            [max_input_size: :disabled],
            [dirty_threshold: "64"],
            [dirty_threshold: -1],
            [unknown: true]
          ] do
        assert_raise ArgumentError, fn -> EncodingRs.max_input_size(opts) end
      end

      assert_raise ArgumentError, ~r/expected :bom/, fn ->
        EncodingRs.decode("hi", "utf-8", bom: :invalid)
      end

      assert_raise ArgumentError, ~r/expected :on_error/, fn ->
        EncodingRs.decode("hi", "utf-8", on_error: :strict)
      end

      assert_raise ArgumentError, ~r/expected :on_error/, fn ->
        EncodingRs.encode("hi", "utf-8", on_error: :strict)
      end

      for bad_tld <- ["", "JP", ".jp", "co.jp", "日本", 123] do
        assert_raise ArgumentError, ~r/expected :tld/, fn ->
          EncodingRs.detect("hi", tld: bad_tld)
        end
      end

      assert_raise ArgumentError, ~r/expected :allow_utf8/, fn ->
        EncodingRs.detect("hi", allow_utf8: :yes)
      end
    end

    test "ignores application configuration" do
      previous = Application.fetch_env(:encoding_rs, :max_input_size)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:encoding_rs, :max_input_size, value)
          :error -> Application.delete_env(:encoding_rs, :max_input_size)
        end
      end)

      Application.put_env(:encoding_rs, :max_input_size, 4)
      assert EncodingRs.max_input_size() == 100 * 1024 * 1024
      assert {:ok, "hello"} = EncodingRs.decode("hello", "utf-8")
      assert {:ok, "hello"} = EncodingRs.decode("hello", "utf-8", max_input_size: 5)
    end
  end

  describe "roundtrip" do
    test "encode then decode returns original for UTF-8 and legacy encodings" do
      original = "Hello, 世界! 🎉"
      {:ok, encoded} = EncodingRs.encode(original, "utf-8")
      {:ok, decoded} = EncodingRs.decode(encoded, "utf-8")
      assert decoded == original

      for encoding <- ["windows-1252", "iso-8859-1", "windows-1251"] do
        {:ok, encoded} = EncodingRs.encode("Hello World", encoding)
        {:ok, decoded} = EncodingRs.decode(encoded, encoding)
        assert decoded == "Hello World", "Roundtrip failed for #{encoding}"
      end

      for {text, encoding} <- [
            {"こんにちは世界", "shift_jis"},
            {"こんにちは世界", "euc-jp"},
            {"こんにちは世界", "iso-2022-jp"},
            {"你好世界", "gbk"},
            {"繁體中文", "big5"},
            {"안녕하세요", "euc-kr"}
          ] do
        {:ok, encoded} = EncodingRs.encode(text, encoding, on_error: :error)
        {:ok, decoded} = EncodingRs.decode(encoded, encoding, on_error: :error)
        assert decoded == text, "Roundtrip failed for #{encoding}"
      end
    end
  end

  describe "BOM detection and heuristic detect/2" do
    test "detect_bom/1 and detect_and_strip_bom/1 handle UTF-8 and UTF-16 BOMs" do
      assert {:ok, "UTF-8", 3} = EncodingRs.detect_bom(<<0xEF, 0xBB, 0xBF, "hello">>)
      assert {:ok, "UTF-16LE", 2} = EncodingRs.detect_bom(<<0xFF, 0xFE, 0x48, 0x00>>)
      assert {:ok, "UTF-16BE", 2} = EncodingRs.detect_bom(<<0xFE, 0xFF, 0x00, 0x48>>)
      assert {:error, :no_bom} = EncodingRs.detect_bom("hello")
      assert {:error, :no_bom} = EncodingRs.detect_bom(<<>>)
      assert {:error, :no_bom} = EncodingRs.detect_bom(<<0xEF, 0xBB>>)

      assert {:ok, "UTF-8", "hello"} =
               EncodingRs.detect_and_strip_bom(<<0xEF, 0xBB, 0xBF, "hello">>)

      assert {:ok, "UTF-8", ""} = EncodingRs.detect_and_strip_bom(<<0xEF, 0xBB, 0xBF>>)
      assert {:error, :no_bom} = EncodingRs.detect_and_strip_bom("hello")
    end

    test "detect/1 and detect/2 identify BOMs and legacy encodings" do
      assert {:ok, "UTF-8"} = EncodingRs.detect("こんにちは世界")
      assert {:ok, "UTF-16LE"} = EncodingRs.detect(<<0xFF, 0xFE, 0x48, 0x00>>)
      assert {:ok, "UTF-16BE"} = EncodingRs.detect(<<0xFE, 0xFF, 0x00, 0x48>>)

      {:ok, sjis} = EncodingRs.encode("日本語の文章をシフトJISでエンコードします。", "shift_jis")
      assert {:ok, "Shift_JIS"} = EncodingRs.detect(sjis, tld: "jp")

      {:ok, gbk} = EncodingRs.encode("这是一段用于字符编码检测测试的简体中文文本。", "gbk")
      assert {:ok, "GBK"} = EncodingRs.detect(gbk, tld: "cn")

      {:ok, win1251} =
        EncodingRs.encode("Это тестовый текст на русском языке в кодировке.", "windows-1251")

      assert {:ok, "windows-1251"} = EncodingRs.detect(win1251, tld: "ru")

      {:ok, iso2022} = EncodingRs.encode("日本語のメール本文テスト", "iso-2022-jp")
      assert {:ok, "ISO-2022-JP"} = EncodingRs.detect(iso2022, allow_iso_2022_jp: true)

      assert {:ok, "windows-1252"} = EncodingRs.detect("hello", allow_utf8: false)
      assert {:error, :input_too_large} = EncodingRs.detect("hello", max_input_size: 4)
      assert "UTF-8" = EncodingRs.detect!("こんにちは", dirty_threshold: 0)
    end
  end

  describe "batch operations" do
    test "decode_batch/1,2 supports mixed encodings, bom, and strict mode" do
      items = [
        {<<72, 101, 108, 108, 111>>, "windows-1252"},
        {<<0x82, 0xA0>>, "shift_jis"},
        {<<1, 2, 3>>, "invalid-encoding"}
      ]

      assert [{:ok, "Hello"}, {:ok, "あ"}, {:error, :unknown_encoding}] =
               EncodingRs.decode_batch(items)

      assert [] == EncodingRs.decode_batch([])

      assert [{:ok, "hi"}, {:error, :malformed_input}] =
               EncodingRs.decode_batch([{"hi", "utf-8"}, {<<0xFF>>, "utf-8"}], on_error: :error)

      assert [{:ok, "\uFEFFhi"}] =
               EncodingRs.decode_batch([{<<0xEF, 0xBB, 0xBF, "hi">>, "utf-8"}], bom: :preserve)
    end

    test "encode_batch/1,2 and encode_batch_with_details/1,2 handle details, invalid UTF-8, and strict mode" do
      items = [
        {"Hello", "windows-1252"},
        {"🎉", "windows-1252"},
        {<<0xFF>>, "windows-1252"},
        {"x", "utf-16le"},
        {"y", "invalid-encoding"}
      ]

      assert [
               {:ok, "Hello"},
               {:ok, "&#127881;"},
               {:error, :invalid_utf8},
               {:error, :encoder_unavailable},
               {:error, :unknown_encoding}
             ] = EncodingRs.encode_batch(items)

      assert [
               {:ok, "Hello", false},
               {:ok, "&#127881;", true},
               {:error, :invalid_utf8},
               {:error, :encoder_unavailable},
               {:error, :unknown_encoding}
             ] = EncodingRs.encode_batch_with_details(items)

      assert [
               {:ok, "Hello", false},
               {:error, :unmappable_character}
             ] =
               EncodingRs.encode_batch_with_details(
                 [{"Hello", "windows-1252"}, {"🎉", "windows-1252"}],
                 on_error: :error
               )

      assert [] == EncodingRs.encode_batch([])
      assert [] == EncodingRs.encode_batch_with_details([])
    end

    test "batch operations honor aggregate dirty threshold and per-item max_input_size" do
      decode_items = [{<<72>>, "utf-8"}, {"too big", "utf-8"}, {<<73>>, "utf-8"}]

      for dirty_threshold <- [0, 1024] do
        opts = [dirty_threshold: dirty_threshold, max_input_size: 4]

        assert [{:ok, "H"}, {:error, :input_too_large}, {:ok, "I"}] =
                 EncodingRs.decode_batch(decode_items, opts)

        assert [
                 {:ok, "H", "UTF-8", false},
                 {:error, :input_too_large},
                 {:ok, "I", "UTF-8", false}
               ] = EncodingRs.decode_batch_with_details(decode_items, opts)
      end

      assert [{:error, :input_too_large}, {:error, :input_too_large}] =
               EncodingRs.encode_batch([{"too big", "utf-8"}, {"also big", "utf-8"}],
                 max_input_size: 4
               )
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
  end
end
