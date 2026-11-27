# EncodingRs NIF

Rust NIF (Native Implemented Function) for the `encoding_rs` Elixir package.

This crate provides WHATWG text conversion and heuristic encoding detection powered by Mozilla's [encoding_rs](https://crates.io/crates/encoding_rs) (with `fast-legacy-encode`) and [chardetng](https://crates.io/crates/chardetng) crates.

## Features

- **One-shot and batch conversion**: Decodes all 40 WHATWG encodings and encodes their 37 output encodings with configurable BOM handling (`:sniff`, `:strip`, `:preserve`) and error modes (`:replace`, `:error`).
- **Streaming decoder and encoder**: Stateful resources that preserve multibyte sequences, split UTF-8 code points, and `ISO-2022-JP` shift state across chunk boundaries.
- **BOM and heuristic detection**: Detects UTF-8/UTF-16 BOMs and runs `chardetng` one-shot or incrementally.
- **Dirty schedulers**: Large inputs automatically run on dirty CPU schedulers.

## Building

```bash
# Force build from source
ENCODING_RS_BUILD=true mix compile
```

## Module

Loaded by `EncodingRs.Native`.
