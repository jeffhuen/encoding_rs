defmodule EncodingRs.EncoderTest do
  use ExUnit.Case, async: true
  doctest EncodingRs.Encoder

  alias EncodingRs.Encoder

  describe "new/1,2 and new!/1,2" do
    test "creates encoder for output encodings and rejects decode-only or unknown labels" do
      assert {:ok, encoder} = Encoder.new("shift_jis")
      assert {:ok, <<0x82, 0xA0>>, false} = Encoder.encode_chunk(encoder, "あ", true)
      assert {:ok, _} = Encoder.new("iso-2022-jp", dirty_threshold: 0, max_input_size: 1024)
      assert {:error, :encoder_unavailable} = Encoder.new("utf-16le")
      assert {:error, :encoder_unavailable} = Encoder.new("utf-16be")
      assert {:error, :encoder_unavailable} = Encoder.new("replacement")
      assert {:error, :unknown_encoding} = Encoder.new("not-an-encoding")

      encoder! = Encoder.new!("gbk")
      assert {"hi", false} = Encoder.encode_chunk!(encoder!, "hi", true)

      assert_raise ArgumentError, ~r/encoding is decode-only/, fn ->
        Encoder.new!("utf-16le")
      end

      assert_raise ArgumentError, ~r/unknown encoding/, fn ->
        Encoder.new!("invalid")
      end
    end
  end

  describe "encode_chunk/3,4" do
    test "buffers UTF-8 code points split byte-by-byte across chunks" do
      # 3-byte Japanese char and 4-byte emoji split one byte per chunk
      bytes = :binary.bin_to_list("あ🎉")
      chunks = Enum.map(bytes, &<<&1>>)

      {:ok, encoder} = Encoder.new("shift_jis")

      encoded =
        chunks
        |> Enum.with_index(1)
        |> Enum.map_join(fn {chunk, idx} ->
          is_last = idx == length(chunks)
          {:ok, out, _had_errors} = Encoder.encode_chunk(encoder, chunk, is_last)
          out
        end)

      assert {:ok, expected} = EncodingRs.encode("あ🎉", "shift_jis")
      assert encoded == expected
    end

    test "preserves ISO-2022-JP shift state across chunks without redundant escapes" do
      {:ok, encoder} = Encoder.new("iso-2022-jp")
      {:ok, out1, false} = Encoder.encode_chunk(encoder, "こん", false)
      {:ok, out2, false} = Encoder.encode_chunk(encoder, "にちは", false)
      {:ok, out3, false} = Encoder.encode_chunk(encoder, "", true)

      streamed = out1 <> out2 <> out3
      {:ok, one_shot} = EncodingRs.encode("こんにちは", "iso-2022-jp")
      assert streamed == one_shot

      # Confirm it avoids extra ESC(B / ESC$B transitions compared to chunk-wise one-shot encode
      {:ok, chunk1} = EncodingRs.encode("こん", "iso-2022-jp")
      {:ok, chunk2} = EncodingRs.encode("にちは", "iso-2022-jp")
      assert byte_size(streamed) < byte_size(chunk1 <> chunk2)
    end

    test "rejects invalid UTF-8 and incomplete UTF-8 at EOF" do
      {:ok, enc1} = Encoder.new("windows-1252")
      assert {:error, :invalid_utf8} = Encoder.encode_chunk(enc1, <<0xFF>>, false)

      {:ok, enc2} = Encoder.new("shift_jis")
      <<lead, _::binary>> = "あ"
      assert {:ok, <<>>, false} = Encoder.encode_chunk(enc2, <<lead>>, false)
      assert {:error, :invalid_utf8} = Encoder.encode_chunk(enc2, <<>>, true)
    end

    test "supports strict mode and post-finish guard" do
      {:ok, strict} = Encoder.new("windows-1252", on_error: :error)
      assert {:error, :unmappable_character} = Encoder.encode_chunk(strict, "🎉", false)
      assert {:error, :encoder_finished} = Encoder.encode_chunk(strict, "ok", true)

      {:ok, normal} = Encoder.new("windows-1252")
      assert {:ok, "hi", false} = Encoder.encode_chunk(normal, "hi", true)
      assert {:error, :encoder_finished} = Encoder.encode_chunk(normal, "more", true)
    end

    test "enforces max_input_size per chunk" do
      {:ok, encoder} = Encoder.new("utf-8", max_input_size: 4)
      assert {:error, :input_too_large} = Encoder.encode_chunk(encoder, "hello", true)

      assert {:ok, "hello", false} =
               Encoder.encode_chunk(encoder, "hello", true, max_input_size: 5)
    end
  end

  describe "stream/2,3 and stream!/2,3" do
    test "transcodes file-like byte chunks end-to-end with Decoder and Encoder" do
      original = String.duplicate("Hello世界、日本語テスト12345\n", 100)
      {:ok, sjis_bytes} = EncodingRs.encode(original, "shift_jis")

      # Slice into odd 7-byte chunks to force multibyte splits in both directions
      raw_chunks =
        for <<chunk::binary-size(7) <- sjis_bytes>>, do: chunk

      remainder_size = rem(byte_size(sjis_bytes), 7)

      raw_chunks =
        if remainder_size > 0 do
          raw_chunks ++
            [binary_part(sjis_bytes, byte_size(sjis_bytes) - remainder_size, remainder_size)]
        else
          raw_chunks
        end

      iso2022_bytes =
        raw_chunks
        |> EncodingRs.Decoder.stream!("shift_jis")
        |> Encoder.stream!("iso-2022-jp")
        |> Enum.into(<<>>)

      assert {:ok, ^original} = EncodingRs.decode(iso2022_bytes, "iso-2022-jp", on_error: :error)
    end

    test "non-raising stream emits {:error, reason} on init, chunk, and flush errors" do
      never_pulled = Stream.map([1], fn _ -> raise "upstream should not be enumerated" end)

      assert [{:error, :encoder_unavailable}] =
               never_pulled |> Encoder.stream("utf-16le") |> Enum.to_list()

      assert [{:error, :unknown_encoding}] =
               never_pulled |> Encoder.stream("invalid") |> Enum.to_list()

      assert [{:ok, "ok"}, {:error, :unmappable_character}] =
               ["ok", "🎉", "never"]
               |> Encoder.stream("windows-1252", on_error: :error)
               |> Enum.to_list()

      <<lead, _::binary>> = "あ"

      assert [{:ok, <<>>}, {:error, :invalid_utf8}] =
               [<<lead>>] |> Encoder.stream("shift_jis") |> Enum.to_list()
    end

    test "stream_with_errors and stream_with_errors! report replacements" do
      assert [{:ok, "Hello", false}, {:ok, "&#127881;", true}] =
               ["Hello", "🎉"] |> Encoder.stream_with_errors("windows-1252") |> Enum.to_list()

      assert [{"Hello", false}, {"&#127881;", true}] =
               ["Hello", "🎉"] |> Encoder.stream_with_errors!("windows-1252") |> Enum.to_list()
    end

    test "stream! raises on error" do
      assert_raise ArgumentError, ~r/encoding is decode-only/, fn ->
        ["hi"] |> Encoder.stream!("utf-16le") |> Enum.to_list()
      end

      assert_raise RuntimeError, ~r/unmappable_character/, fn ->
        ["🎉"] |> Encoder.stream!("windows-1252", on_error: :error) |> Enum.to_list()
      end
    end
  end
end
