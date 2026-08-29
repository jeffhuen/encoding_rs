# Migrating from 0.3 to 0.4

Version 0.4 removes global application configuration. Public function arities,
return values, and default limits do not change.

## Replace application configuration

EncodingRs no longer reads these settings:

```elixir
config :encoding_rs,
  dirty_threshold: 128 * 1024,
  max_input_size: 10 * 1024 * 1024
```

Pass the settings to the operation that needs them:

```elixir
EncodingRs.decode(data, "shift_jis",
  dirty_threshold: 128 * 1024,
  max_input_size: 10 * 1024 * 1024
)
```

For a manual chunk loop, set the options once when you create the decoder:

```elixir
{:ok, decoder} =
  EncodingRs.Decoder.new("shift_jis",
    dirty_threshold: 128 * 1024,
    max_input_size: 256 * 1024
  )

EncodingRs.Decoder.decode_chunk(decoder, chunk, false)
```

Streams and batches accept the same options:

```elixir
EncodingRs.Decoder.stream(chunks, "shift_jis", max_input_size: 256 * 1024)
EncodingRs.decode_batch(items, dirty_threshold: 128 * 1024)
```

## Defaults

Calls without options still use a 64KB dirty scheduler threshold and a 100MB
input limit. They do not read or traverse an option list.

## Why this changed

Application configuration is global. A library may serve several consumers in
one VM, and each consumer may need different limits. Explicit options keep that
choice with the caller and avoid hidden runtime state.

## Checklist

1. Change the dependency requirement to `~> 0.4.0`.
2. Find each `config :encoding_rs` entry and move its values to the relevant
   call, stream, batch, or `Decoder.new/2`.
3. Remove the old application configuration.
4. Run the tests that cover large inputs and streaming boundaries.
