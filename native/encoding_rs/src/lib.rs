//! String encoding/decoding NIF for Elixir using Rust's encoding_rs crate.
//!
//! This is a high-performance implementation based on encoding_rs, the same
//! encoding library used by Firefox. It provides fast character encoding
//! decoding for all encodings in the WHATWG Encoding Standard and encoding
//! for their output encodings.
//!
//! Supported encodings include:
//! - UTF-8, plus decode-only UTF-16LE and UTF-16BE
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

use std::sync::Mutex;

use encoding_rs::Encoding;
use rustler::{Atom, Binary, Env, NifResult, OwnedBinary, Resource, ResourceArc};

const ALLOCATION_FAILED: &str = "allocation_failed";
const ENCODER_UNAVAILABLE: &str = "encoder_unavailable";
const LOCK_POISONED: &str = "lock_poisoned";
const UNKNOWN_ENCODING: &str = "unknown_encoding";

mod atoms {
    rustler::atoms! {
        ok,
        error,
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

type DecodeResult = (Atom, String, &'static str, bool);

#[rustler::resource_impl]
impl Resource for DecoderResource {}

/// Decodes a binary from the specified encoding to a UTF-8 string.
///
/// Runs on a dirty CPU scheduler. The Elixir API selects this entry point when
/// the input exceeds its configured threshold.
///
/// ## Arguments
/// * `in_binary` - The binary data to decode
/// * `enc` - The source encoding label (WHATWG format, e.g., "windows-1252")
///
/// ## Returns
/// * `{:ok, string}` on success
/// * `{:error, :unknown_encoding}` if encoding label is not recognized
#[rustler::nif(schedule = "DirtyCpu")]
fn decode_dirty(in_binary: Binary, enc: &str) -> NifResult<(Atom, String)> {
    Ok(decode_impl(in_binary.as_slice(), enc))
}

#[rustler::nif]
fn decode_normal(in_binary: Binary, enc: &str) -> NifResult<(Atom, String)> {
    Ok(decode_impl(in_binary.as_slice(), enc))
}

/// Decodes while also returning the BOM-selected encoding and replacement status.
#[rustler::nif(schedule = "DirtyCpu")]
fn decode_with_details_dirty(in_binary: Binary, enc: &str) -> NifResult<DecodeResult> {
    Ok(decode_with_details_impl(in_binary.as_slice(), enc))
}

#[rustler::nif]
fn decode_with_details_normal(in_binary: Binary, enc: &str) -> NifResult<DecodeResult> {
    Ok(decode_with_details_impl(in_binary.as_slice(), enc))
}

fn decode_impl(input: &[u8], enc: &str) -> (Atom, String) {
    let (status, value, _, _) = decode_with_details_impl(input, enc);
    (status, value)
}

fn decode_with_details_impl(input: &[u8], enc: &str) -> DecodeResult {
    match Encoding::for_label(enc.as_bytes()) {
        Some(encoding) => {
            let (decoded, actual_encoding, had_errors) = encoding.decode(input);
            // encoding_rs replaces unmappable characters with U+FFFD automatically
            (
                atoms::ok(),
                decoded.into_owned(),
                actual_encoding.name(),
                had_errors,
            )
        }
        None => (atoms::error(), String::new(), "", false),
    }
}

/// Encodes a UTF-8 string to the specified encoding.
///
/// Runs on a dirty CPU scheduler. The Elixir API selects this entry point when
/// the input exceeds its configured threshold.
///
/// ## Arguments
/// * `env` - The Erlang environment
/// * `in_str` - The UTF-8 string to encode
/// * `enc` - The target encoding label (WHATWG format, e.g., "shift_jis")
///
/// ## Returns
/// * `{:ok, binary}` on success
/// * `{:error, :unknown_encoding}` if encoding label is not recognized
/// * `{:error, :encoder_unavailable}` for decode-only encodings
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
        Some(encoding) if encoder_available(encoding) => {
            let (encoded, _, _had_errors) = encoding.encode(in_str);

            let mut bin = OwnedBinary::new(encoded.len())
                .ok_or_else(|| rustler::Error::Term(Box::new(ALLOCATION_FAILED)))?;
            // copy_from_slice is infallible here: bin was allocated with encoded.len()
            bin.as_mut_slice().copy_from_slice(&encoded);

            Ok((atoms::ok(), bin.release(env)))
        }
        Some(_) => encode_error(env, ENCODER_UNAVAILABLE),
        None => encode_error(env, UNKNOWN_ENCODING),
    }
}

fn encoder_available(encoding: &'static Encoding) -> bool {
    encoding == encoding.output_encoding()
}

fn encode_error<'a>(env: Env<'a>, reason: &'static str) -> NifResult<(Atom, Binary<'a>)> {
    let mut bin = OwnedBinary::new(reason.len())
        .ok_or_else(|| rustler::Error::Term(Box::new(ALLOCATION_FAILED)))?;
    bin.as_mut_slice().copy_from_slice(reason.as_bytes());
    Ok((atoms::error(), bin.release(env)))
}

/// Checks if an encoding label is recognized for decoding.
///
/// ## Arguments
/// * `enc` - The encoding label to check
///
/// ## Returns
/// * `true` if the decoding label is recognized
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
fn canonical_name(enc: &str) -> (Atom, &'static str) {
    match Encoding::for_label(enc.as_bytes()) {
        Some(encoding) => (atoms::ok(), encoding.name()),
        None => (atoms::error(), UNKNOWN_ENCODING),
    }
}

/// Lists all recognized encoding names.
///
/// ## Returns
/// A list of all canonical decoding names recognized by this library.
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
/// ## Arguments
/// * `items` - List of `{binary, encoding}` tuples to decode
///
/// ## Returns
/// List of `{:ok, string}` or `{:error, :unknown_encoding}` tuples,
/// in the same order as the input.
#[rustler::nif]
fn decode_batch_normal(items: Vec<(Binary, &str)>) -> Vec<(Atom, String)> {
    decode_batch_impl(items)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_batch(items: Vec<(Binary, &str)>) -> Vec<(Atom, String)> {
    decode_batch_impl(items)
}

fn decode_batch_impl(items: Vec<(Binary, &str)>) -> Vec<(Atom, String)> {
    items
        .into_iter()
        .map(|(binary, enc)| decode_impl(binary.as_slice(), enc))
        .collect()
}

/// Batch decode variant that includes BOM selection and replacement status.
#[rustler::nif]
fn decode_batch_with_details_normal(items: Vec<(Binary, &str)>) -> Vec<DecodeResult> {
    decode_batch_with_details_impl(items)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_batch_with_details(items: Vec<(Binary, &str)>) -> Vec<DecodeResult> {
    decode_batch_with_details_impl(items)
}

fn decode_batch_with_details_impl(items: Vec<(Binary, &str)>) -> Vec<DecodeResult> {
    items
        .into_iter()
        .map(|(binary, enc)| decode_with_details_impl(binary.as_slice(), enc))
        .collect()
}

/// Encodes multiple strings in a single NIF call.
///
/// This amortizes NIF dispatch overhead when processing many items,
/// making it more efficient than calling `encode` repeatedly.
///
/// ## Arguments
/// * `env` - The Erlang environment
/// * `items` - List of `{string, encoding}` tuples to encode
///
/// ## Returns
/// List of `{:ok, binary}`, `{:error, :unknown_encoding}`, or
/// `{:error, :encoder_unavailable}` tuples,
/// in the same order as the input.
#[rustler::nif]
fn encode_batch_normal<'a>(
    env: Env<'a>,
    items: Vec<(&str, &str)>,
) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    encode_batch_impl(env, items)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_batch<'a>(env: Env<'a>, items: Vec<(&str, &str)>) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    encode_batch_impl(env, items)
}

fn encode_batch_impl<'a>(
    env: Env<'a>,
    items: Vec<(&str, &str)>,
) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    items
        .into_iter()
        .map(|(in_str, enc)| encode_impl(env, in_str, enc))
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
fn detect_bom(data: Binary) -> (Atom, &'static str, usize) {
    match Encoding::for_bom(data.as_slice()) {
        Some((encoding, bom_length)) => (atoms::ok(), encoding.name(), bom_length),
        None => (atoms::error(), "no_bom", 0),
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
    let mut decoder = match decoder_ref.decoder.lock() {
        Ok(guard) => guard,
        Err(_) => return Ok((atoms::error(), String::from(LOCK_POISONED), false)),
    };

    let input = chunk.as_slice();
    let Ok(mut output) = allocate_decode_output(&decoder, input.len()) else {
        return Ok((atoms::error(), String::from(ALLOCATION_FAILED), false));
    };
    let (_result, _read, had_errors) = decoder.decode_to_string(input, &mut output, is_last);

    // Release excess capacity before Rustler copies this into a BEAM binary.
    // Skip for small buffers where the realloc overhead outweighs the savings.
    let excess = output.capacity() - output.len();
    if excess > 4096 {
        output.shrink_to_fit();
    }

    Ok((atoms::ok(), output, had_errors))
}

fn allocate_decode_output(
    decoder: &encoding_rs::Decoder,
    input_len: usize,
) -> Result<String, &'static str> {
    let max_output_len = decoder
        .max_utf8_buffer_length(input_len)
        .ok_or(ALLOCATION_FAILED)?;

    // Avoid a capacity-overflow panic crossing the NIF boundary.
    let mut output = String::new();
    output
        .try_reserve(max_output_len)
        .map_err(|_| ALLOCATION_FAILED)?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_output_allocation_rejects_overflowing_length() {
        let decoder = encoding_rs::UTF_8.new_decoder();

        assert_eq!(
            allocate_decode_output(&decoder, usize::MAX),
            Err(ALLOCATION_FAILED)
        );
    }

    #[test]
    fn only_output_encodings_have_encoders() {
        assert!(encoder_available(encoding_rs::UTF_8));
        assert!(!encoder_available(encoding_rs::UTF_16LE));
        assert!(!encoder_available(encoding_rs::UTF_16BE));
        assert!(!encoder_available(encoding_rs::REPLACEMENT));
    }
}

rustler::init!("Elixir.EncodingRs.Native");
