//! String encoding/decoding NIF for Elixir using Rust's encoding_rs crate.
//!
//! This is a high-performance implementation based on encoding_rs, the same
//! encoding library used by Firefox. It provides fast character encoding
//! conversion for all encodings in the WHATWG Encoding Standard.
//!
//! Supported encodings include:
//! - UTF-8, UTF-16LE, UTF-16BE
//! - Windows code pages (1250-1258, 874, 949, 932)
//! - ISO-8859 family (1-16)
//! - Asian encodings (Shift_JIS, EUC-JP, EUC-KR, GBK, GB18030, Big5)
//! - And many more from the WHATWG Encoding Standard
//!
//! ## Streaming Support
//!
//! For streaming/chunked decoding of multibyte encodings, use the stateful
//! decoder API (`decoder_new`, `decoder_decode_chunk`) which properly handles
//! characters split across chunk boundaries.

use encoding_rs::Encoding;
use rustler::{Atom, Binary, Env, NifResult, OwnedBinary, ResourceArc};
use std::io::Write;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unknown_encoding,
        encode_error,
        decode_error,
        no_bom,
    }
}

/// Stateful decoder resource for streaming decoding.
///
/// Wraps an `encoding_rs::Decoder` in a Mutex for safe concurrent access
/// from the BEAM. The decoder maintains internal state for incomplete
/// multibyte sequences between chunk boundaries.
pub struct DecoderResource {
    decoder: Mutex<encoding_rs::Decoder>,
}

/// Decodes a binary from the specified encoding to a UTF-8 string.
///
/// Uses dirty CPU scheduler for binaries larger than 64KB to avoid
/// blocking the BEAM scheduler.
///
/// ## Arguments
/// * `in_binary` - The binary data to decode
/// * `enc` - The source encoding label (WHATWG format, e.g., "windows-1252")
///
/// ## Returns
/// * `{:ok, string}` on success
/// * `{:error, :unknown_encoding}` if encoding label is not recognized
#[rustler::nif(schedule = "DirtyCpu")]
fn decode_dirty<'a>(env: Env<'a>, in_binary: Binary, enc: &str) -> NifResult<(Atom, String)> {
    decode_impl(env, in_binary, enc)
}

#[rustler::nif]
fn decode_normal<'a>(env: Env<'a>, in_binary: Binary, enc: &str) -> NifResult<(Atom, String)> {
    decode_impl(env, in_binary, enc)
}

fn decode_impl<'a>(_env: Env<'a>, in_binary: Binary, enc: &str) -> NifResult<(Atom, String)> {
    match Encoding::for_label(enc.as_bytes()) {
        Some(encoding) => {
            let (decoded, _, _had_errors) = encoding.decode(in_binary.as_slice());
            // encoding_rs replaces unmappable characters with U+FFFD automatically
            Ok((atoms::ok(), decoded.into_owned()))
        }
        None => Ok((atoms::error(), "unknown_encoding".to_string())),
    }
}

/// Encodes a UTF-8 string to the specified encoding.
///
/// Uses dirty CPU scheduler for strings larger than 64KB to avoid
/// blocking the BEAM scheduler.
///
/// ## Arguments
/// * `env` - The Erlang environment
/// * `in_str` - The UTF-8 string to encode
/// * `enc` - The target encoding label (WHATWG format, e.g., "shift_jis")
///
/// ## Returns
/// * `{:ok, binary}` on success
/// * `{:error, :unknown_encoding}` if encoding label is not recognized
#[rustler::nif(schedule = "DirtyCpu")]
fn encode_dirty<'a>(env: Env<'a>, in_str: &str, enc: &str) -> NifResult<(Atom, Binary<'a>)> {
    encode_impl(env, in_str, enc)
}

#[rustler::nif]
fn encode_normal<'a>(env: Env<'a>, in_str: &str, enc: &str) -> NifResult<(Atom, Binary<'a>)> {
    encode_impl(env, in_str, enc)
}

fn encode_impl<'a>(env: Env<'a>, in_str: &str, enc: &str) -> NifResult<(Atom, Binary<'a>)> {
    match Encoding::for_label(enc.as_bytes()) {
        Some(encoding) => {
            let (encoded, _, _had_errors) = encoding.encode(in_str);
            // encoding_rs replaces unmappable characters automatically

            let mut bin = OwnedBinary::new(encoded.len())
                .ok_or_else(|| rustler::Error::Term(Box::new("allocation_failed")))?;
            bin.as_mut_slice()
                .write_all(&encoded)
                .map_err(|_| rustler::Error::Term(Box::new("write_failed")))?;

            Ok((atoms::ok(), bin.release(env)))
        }
        None => {
            // Return empty binary for error case
            let bin = OwnedBinary::new(0)
                .ok_or_else(|| rustler::Error::Term(Box::new("allocation_failed")))?;
            Ok((atoms::error(), bin.release(env)))
        }
    }
}

/// Checks if an encoding label is valid/supported.
///
/// ## Arguments
/// * `enc` - The encoding label to check
///
/// ## Returns
/// * `true` if the encoding is supported
/// * `false` otherwise
#[rustler::nif]
fn encoding_exists(enc: &str) -> bool {
    Encoding::for_label(enc.as_bytes()).is_some()
}

/// Returns the canonical name for an encoding label.
///
/// ## Arguments
/// * `enc` - The encoding label (can be an alias)
///
/// ## Returns
/// * `{:ok, name}` with the canonical encoding name
/// * `{:error, :unknown_encoding}` if not recognized
#[rustler::nif]
fn canonical_name(enc: &str) -> (Atom, String) {
    match Encoding::for_label(enc.as_bytes()) {
        Some(encoding) => (atoms::ok(), encoding.name().to_string()),
        None => (atoms::error(), "unknown_encoding".to_string()),
    }
}

/// Lists all supported encoding names.
///
/// ## Returns
/// A list of all canonical encoding names supported by this library.
#[rustler::nif]
fn list_encodings() -> Vec<&'static str> {
    // encoding_rs doesn't expose a list, so we provide the WHATWG standard ones
    vec![
        "UTF-8",
        "IBM866",
        "ISO-8859-2",
        "ISO-8859-3",
        "ISO-8859-4",
        "ISO-8859-5",
        "ISO-8859-6",
        "ISO-8859-7",
        "ISO-8859-8",
        "ISO-8859-8-I",
        "ISO-8859-10",
        "ISO-8859-13",
        "ISO-8859-14",
        "ISO-8859-15",
        "ISO-8859-16",
        "KOI8-R",
        "KOI8-U",
        "macintosh",
        "windows-874",
        "windows-1250",
        "windows-1251",
        "windows-1252",
        "windows-1253",
        "windows-1254",
        "windows-1255",
        "windows-1256",
        "windows-1257",
        "windows-1258",
        "x-mac-cyrillic",
        "GBK",
        "gb18030",
        "Big5",
        "EUC-JP",
        "ISO-2022-JP",
        "Shift_JIS",
        "EUC-KR",
        "replacement",
        "UTF-16BE",
        "UTF-16LE",
        "x-user-defined",
    ]
}

// =============================================================================
// Batch Operations
// =============================================================================

/// Decodes multiple binaries in a single NIF call.
///
/// This amortizes NIF dispatch overhead when processing many items,
/// making it more efficient than calling `decode` repeatedly.
///
/// Always uses dirty CPU scheduler since batch operations are typically
/// used for throughput-focused workloads.
///
/// ## Arguments
/// * `items` - List of `{binary, encoding}` tuples to decode
///
/// ## Returns
/// List of `{:ok, string}` or `{:error, :unknown_encoding}` tuples,
/// in the same order as the input.
#[rustler::nif(schedule = "DirtyCpu")]
fn decode_batch(items: Vec<(Binary, &str)>) -> Vec<(Atom, String)> {
    items
        .into_iter()
        .map(|(binary, enc)| match Encoding::for_label(enc.as_bytes()) {
            Some(encoding) => {
                let (decoded, _, _had_errors) = encoding.decode(binary.as_slice());
                (atoms::ok(), decoded.into_owned())
            }
            None => (atoms::error(), "unknown_encoding".to_string()),
        })
        .collect()
}

/// Encodes multiple strings in a single NIF call.
///
/// This amortizes NIF dispatch overhead when processing many items,
/// making it more efficient than calling `encode` repeatedly.
///
/// Always uses dirty CPU scheduler since batch operations are typically
/// used for throughput-focused workloads.
///
/// ## Arguments
/// * `env` - The Erlang environment
/// * `items` - List of `{string, encoding}` tuples to encode
///
/// ## Returns
/// List of `{:ok, binary}` or `{:error, :unknown_encoding}` tuples,
/// in the same order as the input.
#[rustler::nif(schedule = "DirtyCpu")]
fn encode_batch<'a>(env: Env<'a>, items: Vec<(&str, &str)>) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    items
        .into_iter()
        .map(|(in_str, enc)| match Encoding::for_label(enc.as_bytes()) {
            Some(encoding) => {
                let (encoded, _, _had_errors) = encoding.encode(in_str);
                let mut bin = OwnedBinary::new(encoded.len())
                    .ok_or_else(|| rustler::Error::Term(Box::new("allocation_failed")))?;
                bin.as_mut_slice()
                    .write_all(&encoded)
                    .map_err(|_| rustler::Error::Term(Box::new("write_failed")))?;
                Ok((atoms::ok(), bin.release(env)))
            }
            None => {
                let bin = OwnedBinary::new(0)
                    .ok_or_else(|| rustler::Error::Term(Box::new("allocation_failed")))?;
                Ok((atoms::error(), bin.release(env)))
            }
        })
        .collect()
}

// =============================================================================
// BOM Detection
// =============================================================================

/// Detects the encoding from a Byte Order Mark (BOM) at the start of the data.
///
/// BOMs are special byte sequences at the beginning of a file that indicate
/// the encoding:
/// - UTF-8: EF BB BF (3 bytes)
/// - UTF-16LE: FF FE (2 bytes)
/// - UTF-16BE: FE FF (2 bytes)
///
/// ## Arguments
/// * `data` - The binary data to check (only first 3 bytes are examined)
///
/// ## Returns
/// * `{:ok, encoding_name, bom_length}` if a BOM is found
/// * `{:error, :no_bom}` if no BOM is present
#[rustler::nif]
fn detect_bom(data: Binary) -> (Atom, String, usize) {
    match Encoding::for_bom(data.as_slice()) {
        Some((encoding, bom_length)) => (atoms::ok(), encoding.name().to_string(), bom_length),
        None => (atoms::error(), "no_bom".to_string(), 0),
    }
}

// =============================================================================
// Streaming Decoder API
// =============================================================================

/// Creates a new stateful decoder for the specified encoding.
///
/// The decoder maintains internal state for handling multibyte characters
/// that may be split across chunk boundaries in streaming scenarios.
///
/// ## Arguments
/// * `enc` - The source encoding label (WHATWG format, e.g., "shift_jis")
///
/// ## Returns
/// * `{:ok, decoder_ref}` on success
/// * `{:error, :unknown_encoding}` if encoding label is not recognized
#[rustler::nif]
fn decoder_new(enc: &str) -> (Atom, Option<ResourceArc<DecoderResource>>) {
    match Encoding::for_label(enc.as_bytes()) {
        Some(encoding) => {
            let decoder = encoding.new_decoder();
            let resource = ResourceArc::new(DecoderResource {
                decoder: Mutex::new(decoder),
            });
            (atoms::ok(), Some(resource))
        }
        None => (atoms::error(), None),
    }
}

/// Decodes a chunk of bytes using the stateful decoder.
///
/// This function properly handles multibyte characters split across chunk
/// boundaries by maintaining decoder state between calls.
///
/// ## Arguments
/// * `decoder_ref` - The decoder resource from `decoder_new`
/// * `chunk` - The binary chunk to decode
/// * `is_last` - Set to `true` for the final chunk to flush any remaining state
///
/// ## Returns
/// * `{:ok, output_string, had_errors}` on success
///   - `output_string`: The decoded UTF-8 string for this chunk
///   - `had_errors`: `true` if any bytes were replaced with U+FFFD
///
/// ## Notes
/// When `is_last` is `false`, incomplete byte sequences at the end of the chunk
/// are buffered internally and will be completed with the next chunk.
/// When `is_last` is `true`, any incomplete sequences are replaced with U+FFFD.
#[rustler::nif]
fn decoder_decode_chunk(
    decoder_ref: ResourceArc<DecoderResource>,
    chunk: Binary,
    is_last: bool,
) -> NifResult<(Atom, String, bool)> {
    decoder_decode_chunk_impl(decoder_ref, chunk, is_last)
}

/// Decodes a chunk using a dirty CPU scheduler for large chunks.
#[rustler::nif(schedule = "DirtyCpu")]
fn decoder_decode_chunk_dirty(
    decoder_ref: ResourceArc<DecoderResource>,
    chunk: Binary,
    is_last: bool,
) -> NifResult<(Atom, String, bool)> {
    decoder_decode_chunk_impl(decoder_ref, chunk, is_last)
}

fn decoder_decode_chunk_impl(
    decoder_ref: ResourceArc<DecoderResource>,
    chunk: Binary,
    is_last: bool,
) -> NifResult<(Atom, String, bool)> {
    let mut decoder = decoder_ref
        .decoder
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock_poisoned")))?;

    let input = chunk.as_slice();

    // Calculate maximum output size: worst case is 3 bytes per input byte for UTF-8
    // plus potential replacement characters
    let max_output_len = decoder
        .max_utf8_buffer_length(input.len())
        .unwrap_or(input.len() * 3 + 3);

    let mut output = String::with_capacity(max_output_len);
    let (_result, _read, had_errors) = decoder.decode_to_string(input, &mut output, is_last);

    Ok((atoms::ok(), output, had_errors))
}

#[allow(non_local_definitions)]
fn on_load(env: Env, _info: rustler::Term) -> bool {
    let _ = rustler::resource!(DecoderResource, env);
    true
}

rustler::init!("Elixir.EncodingRs.Native", load = on_load);
