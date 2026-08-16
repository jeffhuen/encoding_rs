# EncodingRs NIF

Rust NIF (Native Implemented Function) for the EncodingRs Elixir package.

This crate provides high-performance character encoding/decoding using Rust's [encoding_rs](https://crates.io/crates/encoding_rs) library - the same encoding library used by Firefox.

## Features

- **One-shot encoding/decoding**: Convert complete binaries using WHATWG encodings (UTF-16 is decode-only)
- **Streaming decoder**: Stateful decoder for chunked data that properly handles multibyte characters split across chunk boundaries
- **BOM detection**: Detect UTF-8/UTF-16LE/UTF-16BE byte order marks
- **Dirty schedulers**: Large operations automatically use dirty CPU schedulers

## Building

The NIF is built automatically with the Elixir project:

```bash
# Force build from source
ENCODING_RS_BUILD=true mix compile
```

## Module

The NIF is loaded by `EncodingRs.Native` in the Elixir code.
