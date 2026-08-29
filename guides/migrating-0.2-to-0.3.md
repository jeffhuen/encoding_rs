# Migrating from 0.2 to 0.3

This guide describes version 0.3. To upgrade to 0.4, follow the
[0.3 to 0.4 guide](migrating-0.3-to-0.4.md) after this one.

Version 0.3 keeps the existing public function arities and success tuples. It
raises the minimum Elixir version and stops encode operations from accepting
decode-only labels.

## Required: Elixir 1.15 or newer

EncodingRs now requires Elixir 1.15 because Rustler 0.38 and
`rustler_precompiled` 0.9 require it. Applications on Elixir 1.12–1.14 must
upgrade Elixir before updating EncodingRs.

```elixir
def deps do
  [{:encoding_rs, "~> 0.3.0"}]
end
```

## Per-operation options

Scheduler and input limits can now be selected at each call site:

```elixir
EncodingRs.decode(data, "shift_jis",
  dirty_threshold: 128 * 1024,
  max_input_size: 10 * 1024 * 1024
)
```

| API | Options apply to |
|---|---|
| `encode/3`, `decode/3`, `decode_with_details/3` | The complete input |
| `encode_batch/2`, `decode_batch/2`, `decode_batch_with_details/2` | Each item's size limit and the batch's combined scheduler threshold |
| `Decoder.new/2` | Every manual chunk decoded with that decoder |
| `Decoder.decode_chunk/4` | That chunk |
| `Decoder.stream/3`, `Decoder.stream_with_errors/3` | Every chunk in that stream |

Supported options are:

- `:dirty_threshold` — non-negative byte count; defaults to 65,536.
- `:max_input_size` — non-negative byte count or `:infinity`; defaults to
  104,857,600.

Options are validated with `Keyword.validate!/2`. Unknown keys and invalid
values raise `ArgumentError` instead of being ignored.

Existing `config :encoding_rs` values remain valid compatibility fallbacks.
Explicit options take precedence. `:dirty_threshold` remains a compile-time
fallback and `:max_input_size` remains a runtime fallback. No deprecation
warning is emitted during encoding or decoding.

## Batch scheduler behavior changed

In 0.2, batch operations always ran on a dirty CPU scheduler. In 0.3, valid
items are totaled and the batch follows `:dirty_threshold`, just like a
one-shot operation. Oversized items are rejected before this total is
calculated.

To retain the 0.2 always-dirty behavior:

```elixir
EncodingRs.decode_batch(items, dirty_threshold: 0)
EncodingRs.encode_batch(items, dirty_threshold: 0)
```

The batch still crosses the NIF boundary once and preserves input order.

## Detailed decoding is additive

`decode/2` and `decode/3` still return `{:ok, string}`. Use the new detailed API
when replacement or BOM selection must be observable:

```elixir
{:ok, string, actual_encoding, had_errors} =
  EncodingRs.decode_with_details(data, "windows-1252")
```

The batch equivalent is `decode_batch_with_details/2`. Return shapes do not
depend on an option such as `return_errors: true`; callers choose the function
whose contract they need.

One-shot decoding has always allowed a leading UTF-8 or UTF-16 BOM to select
the actual decoder. Version 0.3 documents that behavior and exposes
`actual_encoding`; it does not change the `decode/2` success tuple.

Only the native sentinel for an unrecognized encoding is normalized to
`:unknown_encoding`. Unexpected native error reasons are now preserved instead
of being mislabeled. Callers should retain a general `{:error, reason}` branch.

## Stateful decoder contracts

`Decoder.new/1` still returns the same opaque reference. Existing
`decode_chunk/2`, `decode_chunk/3`, `decode_chunk!/2`, and `decode_chunk!/3`
calls remain valid. `Decoder.new/2` and `new!/2` return an opaque configured
decoder that stores validated options once. The other new option-taking forms
are `decode_chunk/4`, `stream/3`, and `stream_with_errors/3`.

Stream options are resolved once when enumeration starts, then reused for all
chunks. For manual loops, prefer `new/2` plus `decode_chunk/3`.

`Decoder.decode_chunk/4` may return `{:error, :allocation_failed}` if its output
buffer cannot be allocated. This is in addition to `:input_too_large` and
`:lock_poisoned`. Code that exhaustively matches decoder errors should add a
fallback or handle this atom.

## Other API additions and clarifications

- `EncodingRs.available?/0` checks whether the native implementation loaded
  without raising for `:nif_not_loaded` or `:undef`.
- Existing application startup behavior is unchanged. The package no longer
  sets project-only `start_permanent` metadata.

## Decode-only labels now fail encoding

In 0.2, encoding to UTF-16LE, UTF-16BE, or `replacement` silently produced
UTF-8 because those WHATWG encodings have UTF-8 as their output encoding. In
0.3, one-shot and batch encode operations return
`{:error, :encoder_unavailable}` instead. Bang variants raise `ArgumentError`.

Use a dedicated UTF-16 encoder when UTF-16 output is required.

## Upgrade checklist

1. Upgrade to Elixir 1.15 or newer.
2. Change the dependency requirement to `~> 0.3.0` and refresh the lockfile.
3. If batches must always use dirty schedulers, pass `dirty_threshold: 0`.
4. Audit encode calls that pass UTF-16 or `replacement` labels.
5. Audit exhaustive matches on stateful decoder errors.
6. Use explicit operation options for reusable libraries; existing application
   configuration can remain while migrating call sites.
