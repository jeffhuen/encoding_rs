# EncodingRs usage rules

## Overview

`EncodingRs` converts between UTF-8 and all 40 WHATWG encodings (37 output encodings) and detects unlabeled encodings via Rust NIFs powered by Mozilla's `encoding_rs` and `chardetng` crates.

## Choose the right API

### One-shot (`EncodingRs`)

Use `decode/2,3`, `decode_with_details/2,3`, `encode/2,3`, `encode_with_details/2,3`, and `detect/1,2` for complete binaries in memory.

```elixir
{:ok, string} = EncodingRs.decode(binary, "shift_jis")
{:ok, string, actual_encoding, had_errors} = EncodingRs.decode_with_details(binary, "shift_jis")
{:ok, bytes, had_errors} = EncodingRs.encode_with_details("🎉", "windows-1252")
{:ok, encoding} = EncodingRs.detect(unknown_bytes, tld: "jp")
```

### Batch (`decode_batch/1,2`, `decode_batch_with_details/1,2`, `encode_batch/1,2`, `encode_batch_with_details/1,2`)

Use batch calls for lists of independent items to amortize NIF dispatch overhead. The combined byte size of valid items selects normal or dirty CPU scheduling.

### Streaming (`EncodingRs.Decoder`, `EncodingRs.Encoder`, `EncodingRs.Detector`)

Use streaming modules for files and network streams:

- `Decoder.stream/2,3` and `Encoder.stream/2,3` emit `{:ok, chunk}` or `{:error, reason}` without raising.
- `Decoder.stream!/2,3` and `Encoder.stream!/2,3` emit plain binaries and raise on error.
- `Decoder.stream_with_errors/2,3` and `Encoder.stream_with_errors/2,3` emit `{:ok, chunk, had_errors}` or `{:error, reason}`.
- `Detector.detect_stream/1,2` detects the encoding of a chunked stream.

Do not call one-shot `decode/2` or `encode/2` per chunk on streamed data. Multibyte characters and `ISO-2022-JP` shift states break across chunk boundaries.

## Error handling and strict mode

- By default (`on_error: :replace`), decode substitutes `U+FFFD` for malformed bytes and encode substitutes WHATWG HTML decimal numeric character references (such as `&#127881;`) for unmappable characters.
- Pass `on_error: :error` to fail with `{:error, :malformed_input}` (decode) or `{:error, :unmappable_character}` (encode).
- Non-bang encode functions return `{:error, :invalid_utf8}` for invalid UTF-8 input. Bang variants raise `ArgumentError`.
- Decode-only labels (`"utf-16le"`, `"utf-16be"`, `"replacement"`) return `{:error, :encoder_unavailable}` on encode. Use `:unicode.characters_to_binary(str, :utf8, {:utf16, :little})` or `{:utf16, :big}` for UTF-16 output.
- Calling `Decoder.decode_chunk/3`, `Encoder.encode_chunk/3`, or `Detector.feed/3` after `is_last: true` returns `{:error, :decoder_finished}`, `{:error, :encoder_finished}`, or `{:error, :detector_finished}`.

## BOM control and label helpers

- Control decode BOM behavior with `bom: :sniff` (default, overrides encoding on UTF-8 or UTF-16 BOM), `bom: :strip` (removes only a matching BOM), or `bom: :preserve` (keeps `U+FEFF`).
- Validate decoding labels with `EncodingRs.encoding_exists?/1` and encoding labels with `EncodingRs.can_encode?/1`.
- Normalize aliases with `EncodingRs.canonical_name/1` and inspect WHATWG output mappings with `EncodingRs.output_encoding/1`.

## Performance and safety limits

- Default `:dirty_threshold` is 64 KB; default `:max_input_size` is 100 MB. Pass overrides per operation or once on `Decoder.new/2`, `Encoder.new/2`, or `Detector.new/1`.
- Pass `max_input_size: :infinity` only for trusted inputs bounded by another layer.
- Do not share a `Decoder`, `Encoder`, or `Detector` across concurrent processes; create one per logical stream.
- When passing `:tld` to `detect/2` or `Detector.guess/2`, pass a lowercase ASCII label without dots (such as `"jp"` or `"cn"`).
