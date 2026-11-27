# Migrating from 0.4 to 0.5

Version 0.5 raises the minimum Elixir version to 1.16, makes non-bang streams return tagged tuples instead of raising, and returns `{:error, :invalid_utf8}` when encode functions receive invalid UTF-8 bytes.

## Upgrade Elixir to 1.16 or newer (and Rust 1.88+ for source builds)

`rustler_precompiled` 0.10 drops support for Elixir 1.15. If your application runs on Elixir 1.15, upgrade Elixir to 1.16 or newer before updating `encoding_rs`.

If you compile the NIF from source (`ENCODING_RS_BUILD=true`), upgrade Rust to `1.88` or newer (required by the `encoding_rs` `0.8.40+` crate). Precompiled binary users do not need Rust installed.

```elixir
def deps do
  [
    {:encoding_rs, "~> 0.5.0"}
  ]
end
```

## Update streaming decoder calls

In 0.4, `EncodingRs.Decoder.stream/2` and `EncodingRs.Decoder.stream/3` emitted plain strings and raised on errors. `stream_with_errors/2` and `stream_with_errors/3` emitted `{chunk, had_errors}` tuples and raised on errors.

In 0.5, the non-bang stream functions return tagged tuples and stop on errors without raising:

- `EncodingRs.Decoder.stream/2,3` emits `{:ok, chunk}` or `{:error, reason}`.
- `EncodingRs.Decoder.stream_with_errors/2,3` emits `{:ok, chunk, had_errors}` or `{:error, reason}`.

To keep the 0.4 raising behavior, switch to the bang variants:

```elixir
# Before (0.4)
File.stream!("data.txt", [], 64 * 1024)
|> EncodingRs.Decoder.stream("shift_jis")
|> Enum.join()

# After (0.5, raising)
File.stream!("data.txt", [], 64 * 1024)
|> EncodingRs.Decoder.stream!("shift_jis")
|> Enum.join()
```

```elixir
# Before (0.4)
File.stream!("data.txt", [], 64 * 1024)
|> EncodingRs.Decoder.stream_with_errors("shift_jis")
|> Enum.each(fn {chunk, had_errors} -> handle(chunk, had_errors) end)

# After (0.5, raising)
File.stream!("data.txt", [], 64 * 1024)
|> EncodingRs.Decoder.stream_with_errors!("shift_jis")
|> Enum.each(fn {chunk, had_errors} -> handle(chunk, had_errors) end)
```

To handle errors without exceptions, match the tagged tuples from `stream/2,3`:

```elixir
File.stream!("data.txt", [], 64 * 1024)
|> EncodingRs.Decoder.stream("shift_jis", on_error: :error)
|> Enum.reduce_while([], fn
  {:ok, chunk}, acc -> {:cont, [chunk | acc]}
  {:error, reason}, _acc -> {:halt, {:error, reason}}
end)
```

## Handle `{:error, :invalid_utf8}` from encode functions

In 0.4, passing non-UTF-8 bytes to `EncodingRs.encode/2` or `EncodingRs.encode_batch/1` raised `ArgumentError` at the NIF boundary.

In 0.5, non-bang encode functions return `{:error, :invalid_utf8}` instead. `EncodingRs.encode!/2` and `EncodingRs.encode!/3` still raise `ArgumentError`.

```elixir
EncodingRs.encode(<<0xFF>>, "windows-1252")
# => {:error, :invalid_utf8}
```

If you exhaustively match error tuples from `encode/2,3` or `encode_batch/1,2`, add clauses for `:invalid_utf8`, `:unmappable_character` (when using `on_error: :error`), and `:allocation_failed`.

## Handle `:decoder_finished` and unified opaque decoder structs

In 0.4, calling `EncodingRs.Decoder.decode_chunk/3` after passing `is_last: true` panicked in the NIF and poisoned the decoder mutex. In 0.5, it returns `{:error, :decoder_finished}` cleanly.

`EncodingRs.Decoder.new/1` and `new!/1` now return the same opaque `%EncodingRs.Decoder{}` struct as `new/2` and `new!/2` instead of a bare reference, matching `EncodingRs.Encoder` and `EncodingRs.Detector`. Remove any `is_reference/1` checks against decoder handles.

## New capabilities in 0.5

These additions are backward compatible:

- **Streaming encoder**: `EncodingRs.Encoder` (`new/2`, `encode_chunk/3,4`, `stream/3`, `stream!/3`, `stream_with_errors/3`, `stream_with_errors!/3`) preserves shift state for `ISO-2022-JP` and buffers UTF-8 code points split across byte chunks.
- **Encoding detection**: `EncodingRs.detect/2`, `EncodingRs.detect!/2`, and `EncodingRs.Detector` detect unknown encodings using BOM checks and Mozilla's `chardetng` crate.
- **Strict mode and encode details**: Pass `on_error: :error` to encode or decode functions to fail on unmappable characters or malformed bytes. Call `EncodingRs.encode_with_details/3` and `EncodingRs.encode_batch_with_details/2` to detect WHATWG HTML numeric character reference substitutions (`&#128512;`).
- **BOM control**: Pass `bom: :sniff`, `bom: :strip`, or `bom: :preserve` to one-shot decode, batch decode, and `EncodingRs.Decoder.new/2`. Call `EncodingRs.Decoder.encoding/1` to inspect a decoder's active encoding after BOM sniffing.
- **Target encoding inspection**: Call `EncodingRs.can_encode?/1`, `EncodingRs.output_encoding/1`, and `EncodingRs.list_output_encodings/0`.
- **OTP 29 precompiled binaries**: Precompiled assets now include NIF version `2.18` alongside `2.15`, `2.16`, and `2.17`.

## Upgrade checklist

1. Confirm your project runs on Elixir 1.16 or newer.
2. Change the dependency requirement in `mix.exs` to `{:encoding_rs, "~> 0.5.0"}`.
3. Replace `EncodingRs.Decoder.stream/2,3` calls that expect plain strings with `EncodingRs.Decoder.stream!/2,3` (or pattern-match `{:ok, chunk}` and `{:error, reason}`).
4. Replace `EncodingRs.Decoder.stream_with_errors/2,3` calls that expect `{chunk, had_errors}` with `EncodingRs.Decoder.stream_with_errors!/2,3` (or pattern-match `{:ok, chunk, had_errors}` and `{:error, reason}`).
5. Audit exhaustive error matches on `encode/2,3`, `encode_batch/1,2`, and `Decoder.decode_chunk/3,4`.
6. Run your test suite, Credo, and Dialyzer.
