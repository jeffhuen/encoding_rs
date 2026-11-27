//! String encoding, decoding, and detection NIF for Elixir.
//!
//! Powered by Mozilla's `encoding_rs` and `chardetng` crates. Decodes all 40
//! encodings from the WHATWG Encoding Standard, encodes their 37 output
//! encodings, and detects unknown byte encodings heuristically.

use std::borrow::Cow;
use std::sync::Mutex;

use chardetng::{EncodingDetector, Iso2022JpDetection, Utf8Detection};
use encoding_rs::{CoderResult, DecoderResult, EncoderResult, Encoding};
use rustler::{Atom, Binary, Env, NifResult, OwnedBinary, Resource, ResourceArc};

const ALLOCATION_FAILED: &str = "allocation_failed";
const DECODER_FINISHED: &str = "decoder_finished";
const DETECTOR_FINISHED: &str = "detector_finished";
const ENCODER_FINISHED: &str = "encoder_finished";
const ENCODER_UNAVAILABLE: &str = "encoder_unavailable";
const INVALID_BOM_MODE: &str = "invalid_bom_mode";
const INVALID_ON_ERROR: &str = "invalid_on_error";
const INVALID_TLD: &str = "invalid_tld";
const INVALID_UTF8: &str = "invalid_utf8";
const LOCK_POISONED: &str = "lock_poisoned";
const MALFORMED_INPUT: &str = "malformed_input";
const UNKNOWN_ENCODING: &str = "unknown_encoding";
const UNMAPPABLE_CHARACTER: &str = "unmappable_character";

const ALL_ENCODINGS: &[&Encoding] = &[
    encoding_rs::UTF_8,
    encoding_rs::IBM866,
    encoding_rs::ISO_8859_2,
    encoding_rs::ISO_8859_3,
    encoding_rs::ISO_8859_4,
    encoding_rs::ISO_8859_5,
    encoding_rs::ISO_8859_6,
    encoding_rs::ISO_8859_7,
    encoding_rs::ISO_8859_8,
    encoding_rs::ISO_8859_8_I,
    encoding_rs::ISO_8859_10,
    encoding_rs::ISO_8859_13,
    encoding_rs::ISO_8859_14,
    encoding_rs::ISO_8859_15,
    encoding_rs::ISO_8859_16,
    encoding_rs::KOI8_R,
    encoding_rs::KOI8_U,
    encoding_rs::MACINTOSH,
    encoding_rs::WINDOWS_874,
    encoding_rs::WINDOWS_1250,
    encoding_rs::WINDOWS_1251,
    encoding_rs::WINDOWS_1252,
    encoding_rs::WINDOWS_1253,
    encoding_rs::WINDOWS_1254,
    encoding_rs::WINDOWS_1255,
    encoding_rs::WINDOWS_1256,
    encoding_rs::WINDOWS_1257,
    encoding_rs::WINDOWS_1258,
    encoding_rs::X_MAC_CYRILLIC,
    encoding_rs::GBK,
    encoding_rs::GB18030,
    encoding_rs::BIG5,
    encoding_rs::EUC_JP,
    encoding_rs::ISO_2022_JP,
    encoding_rs::SHIFT_JIS,
    encoding_rs::EUC_KR,
    encoding_rs::REPLACEMENT,
    encoding_rs::UTF_16BE,
    encoding_rs::UTF_16LE,
    encoding_rs::X_USER_DEFINED,
];

mod atoms {
    rustler::atoms! {
        ok,
        error,
        sniff,
        strip,
        preserve,
        replace,
    }
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum BomMode {
    Sniff,
    Strip,
    Preserve,
}

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
enum ErrorMode {
    Replace,
    Error,
}

struct DecoderState {
    decoder: encoding_rs::Decoder,
    error_mode: ErrorMode,
    finished: bool,
}

/// Stateful streaming decoder resource.
pub struct DecoderResource {
    state: Mutex<DecoderState>,
}

#[rustler::resource_impl]
impl Resource for DecoderResource {}

struct EncoderState {
    encoder: encoding_rs::Encoder,
    error_mode: ErrorMode,
    pending_utf8: [u8; 4],
    pending_len: usize,
    finished: bool,
}

/// Stateful streaming encoder resource.
pub struct EncoderResource {
    state: Mutex<EncoderState>,
}

#[rustler::resource_impl]
impl Resource for EncoderResource {}

struct DetectorState {
    detector: EncodingDetector,
    check_bom: bool,
    bom_buf: [u8; 3],
    bom_len: usize,
    bom_encoding: Option<&'static Encoding>,
    finished: bool,
}

/// Stateful streaming encoding detector resource.
pub struct DetectorResource {
    state: Mutex<DetectorState>,
}

#[rustler::resource_impl]
impl Resource for DetectorResource {}

type DecodeDetailsResult<'a> = (Atom, Binary<'a>, &'static str, bool);
type EncodeDetailsResult<'a> = (Atom, Binary<'a>, bool);

// =============================================================================
// One-Shot Decoding
// =============================================================================

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_dirty<'a>(
    env: Env<'a>,
    in_binary: Binary,
    enc: &str,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<(Atom, Binary<'a>)> {
    decode_nif(env, in_binary.as_slice(), enc, bom_mode, error_mode)
}

#[rustler::nif]
fn decode_normal<'a>(
    env: Env<'a>,
    in_binary: Binary,
    enc: &str,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<(Atom, Binary<'a>)> {
    decode_nif(env, in_binary.as_slice(), enc, bom_mode, error_mode)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_with_details_dirty<'a>(
    env: Env<'a>,
    in_binary: Binary,
    enc: &str,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<DecodeDetailsResult<'a>> {
    decode_with_details_nif(env, in_binary.as_slice(), enc, bom_mode, error_mode)
}

#[rustler::nif]
fn decode_with_details_normal<'a>(
    env: Env<'a>,
    in_binary: Binary,
    enc: &str,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<DecodeDetailsResult<'a>> {
    decode_with_details_nif(env, in_binary.as_slice(), enc, bom_mode, error_mode)
}

fn decode_nif<'a>(
    env: Env<'a>,
    input: &[u8],
    enc: &str,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<(Atom, Binary<'a>)> {
    let (status, payload, _, _) = decode_with_details_nif(env, input, enc, bom_mode, error_mode)?;
    Ok((status, payload))
}

fn decode_with_details_nif<'a>(
    env: Env<'a>,
    input: &[u8],
    enc: &str,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<DecodeDetailsResult<'a>> {
    let Ok(bom_mode) = parse_bom_mode(bom_mode) else {
        return Ok((
            atoms::error(),
            error_binary(env, INVALID_BOM_MODE)?,
            "",
            false,
        ));
    };
    let Ok(error_mode) = parse_error_mode(error_mode) else {
        return Ok((
            atoms::error(),
            error_binary(env, INVALID_ON_ERROR)?,
            "",
            false,
        ));
    };

    decode_with_details_parsed(env, input, enc, bom_mode, error_mode)
}

fn decode_with_details_parsed<'a>(
    env: Env<'a>,
    input: &[u8],
    enc: &str,
    bom_mode: BomMode,
    error_mode: ErrorMode,
) -> NifResult<DecodeDetailsResult<'a>> {
    match decode_core(input, enc, bom_mode, error_mode) {
        Ok((decoded, actual_encoding, had_errors)) => match alloc_binary(env, decoded.as_bytes()) {
            Ok(bin) => Ok((atoms::ok(), bin, actual_encoding, had_errors)),
            Err(reason) => Ok((atoms::error(), error_binary(env, reason)?, "", false)),
        },
        Err(reason) => Ok((atoms::error(), error_binary(env, reason)?, "", false)),
    }
}

fn decode_core<'a>(
    input: &'a [u8],
    enc: &str,
    bom_mode: BomMode,
    error_mode: ErrorMode,
) -> Result<(Cow<'a, str>, &'static str, bool), &'static str> {
    let Some(encoding) = Encoding::for_label(enc.as_bytes()) else {
        return Err(UNKNOWN_ENCODING);
    };

    match (bom_mode, error_mode) {
        (BomMode::Sniff, ErrorMode::Replace) => {
            let (decoded, actual_encoding, had_errors) = encoding.decode(input);
            Ok((decoded, actual_encoding.name(), had_errors))
        }
        (BomMode::Strip, ErrorMode::Replace) => {
            let (decoded, had_errors) = encoding.decode_with_bom_removal(input);
            Ok((decoded, encoding.name(), had_errors))
        }
        (BomMode::Preserve, ErrorMode::Replace) => {
            let (decoded, had_errors) = encoding.decode_without_bom_handling(input);
            Ok((decoded, encoding.name(), had_errors))
        }
        (BomMode::Sniff, ErrorMode::Error) => {
            let (effective_encoding, slice) = match Encoding::for_bom(input) {
                Some((bom_encoding, bom_len)) => (bom_encoding, &input[bom_len..]),
                None => (encoding, input),
            };
            match effective_encoding.decode_without_bom_handling_and_without_replacement(slice) {
                Some(decoded) => Ok((decoded, effective_encoding.name(), false)),
                None => Err(MALFORMED_INPUT),
            }
        }
        (BomMode::Strip, ErrorMode::Error) => {
            let slice = match Encoding::for_bom(input) {
                Some((bom_encoding, bom_len)) if bom_encoding == encoding => &input[bom_len..],
                _ => input,
            };
            match encoding.decode_without_bom_handling_and_without_replacement(slice) {
                Some(decoded) => Ok((decoded, encoding.name(), false)),
                None => Err(MALFORMED_INPUT),
            }
        }
        (BomMode::Preserve, ErrorMode::Error) => {
            match encoding.decode_without_bom_handling_and_without_replacement(input) {
                Some(decoded) => Ok((decoded, encoding.name(), false)),
                None => Err(MALFORMED_INPUT),
            }
        }
    }
}

// =============================================================================
// One-Shot Encoding
// =============================================================================

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_dirty<'a>(
    env: Env<'a>,
    in_binary: Binary,
    enc: &str,
    error_mode: Atom,
) -> NifResult<(Atom, Binary<'a>)> {
    let (status, payload, _) = encode_with_details_nif(env, in_binary.as_slice(), enc, error_mode)?;
    Ok((status, payload))
}

#[rustler::nif]
fn encode_normal<'a>(
    env: Env<'a>,
    in_binary: Binary,
    enc: &str,
    error_mode: Atom,
) -> NifResult<(Atom, Binary<'a>)> {
    let (status, payload, _) = encode_with_details_nif(env, in_binary.as_slice(), enc, error_mode)?;
    Ok((status, payload))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_with_details_dirty<'a>(
    env: Env<'a>,
    in_binary: Binary,
    enc: &str,
    error_mode: Atom,
) -> NifResult<EncodeDetailsResult<'a>> {
    encode_with_details_nif(env, in_binary.as_slice(), enc, error_mode)
}

#[rustler::nif]
fn encode_with_details_normal<'a>(
    env: Env<'a>,
    in_binary: Binary,
    enc: &str,
    error_mode: Atom,
) -> NifResult<EncodeDetailsResult<'a>> {
    encode_with_details_nif(env, in_binary.as_slice(), enc, error_mode)
}

fn encode_with_details_nif<'a>(
    env: Env<'a>,
    input: &[u8],
    enc: &str,
    error_mode: Atom,
) -> NifResult<EncodeDetailsResult<'a>> {
    let Ok(error_mode) = parse_error_mode(error_mode) else {
        return Ok((atoms::error(), error_binary(env, INVALID_ON_ERROR)?, false));
    };

    encode_with_details_parsed(env, input, enc, error_mode)
}

fn encode_with_details_parsed<'a>(
    env: Env<'a>,
    input: &[u8],
    enc: &str,
    error_mode: ErrorMode,
) -> NifResult<EncodeDetailsResult<'a>> {
    match encode_core(input, enc, error_mode) {
        Ok((encoded, had_errors)) => match alloc_binary(env, &encoded) {
            Ok(bin) => Ok((atoms::ok(), bin, had_errors)),
            Err(reason) => Ok((atoms::error(), error_binary(env, reason)?, false)),
        },
        Err(reason) => Ok((atoms::error(), error_binary(env, reason)?, false)),
    }
}

fn encode_core<'a>(
    input: &'a [u8],
    enc: &str,
    error_mode: ErrorMode,
) -> Result<(Cow<'a, [u8]>, bool), &'static str> {
    let Some(encoding) = Encoding::for_label(enc.as_bytes()) else {
        return Err(UNKNOWN_ENCODING);
    };
    if !encoder_available(encoding) {
        return Err(ENCODER_UNAVAILABLE);
    }
    let Ok(in_str) = std::str::from_utf8(input) else {
        return Err(INVALID_UTF8);
    };

    match error_mode {
        ErrorMode::Replace => {
            let (encoded, _, had_errors) = encoding.encode(in_str);
            Ok((encoded, had_errors))
        }
        ErrorMode::Error => {
            if encoding == encoding_rs::UTF_8 {
                return Ok((Cow::Borrowed(in_str.as_bytes()), false));
            }
            let mut encoder = encoding.new_encoder();
            let encoded = encode_utf8_strict(&mut encoder, in_str, true)?;
            Ok((Cow::Owned(encoded), false))
        }
    }
}

fn encoder_available(encoding: &'static Encoding) -> bool {
    encoding == encoding.output_encoding()
}

// =============================================================================
// Encoding Inspection
// =============================================================================

#[rustler::nif]
fn encoding_exists(enc: &str) -> bool {
    Encoding::for_label(enc.as_bytes()).is_some()
}

#[rustler::nif]
fn can_encode(enc: &str) -> bool {
    Encoding::for_label(enc.as_bytes()).is_some_and(encoder_available)
}

#[rustler::nif]
fn canonical_name(enc: &str) -> (Atom, &'static str) {
    match Encoding::for_label(enc.as_bytes()) {
        Some(encoding) => (atoms::ok(), encoding.name()),
        None => (atoms::error(), UNKNOWN_ENCODING),
    }
}

#[rustler::nif]
fn output_encoding(enc: &str) -> (Atom, &'static str) {
    match Encoding::for_label(enc.as_bytes()) {
        Some(encoding) => (atoms::ok(), encoding.output_encoding().name()),
        None => (atoms::error(), UNKNOWN_ENCODING),
    }
}

#[rustler::nif]
fn list_encodings() -> Vec<&'static str> {
    ALL_ENCODINGS.iter().map(|enc| enc.name()).collect()
}

#[rustler::nif]
fn list_output_encodings() -> Vec<&'static str> {
    ALL_ENCODINGS
        .iter()
        .copied()
        .filter(|enc| encoder_available(enc))
        .map(Encoding::name)
        .collect()
}

// =============================================================================
// Batch Operations
// =============================================================================

#[rustler::nif]
fn decode_batch_normal<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    decode_batch_impl(env, items, bom_mode, error_mode)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_batch<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    decode_batch_impl(env, items, bom_mode, error_mode)
}

fn decode_batch_impl<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    let bom_mode = parse_bom_mode(bom_mode);
    let error_mode = parse_error_mode(error_mode);

    items
        .into_iter()
        .map(|(binary, enc)| match (bom_mode, error_mode) {
            (Ok(bm), Ok(em)) => {
                let (status, payload, _, _) =
                    decode_with_details_parsed(env, binary.as_slice(), enc, bm, em)?;
                Ok((status, payload))
            }
            (Err(reason), _) | (_, Err(reason)) => Ok((atoms::error(), error_binary(env, reason)?)),
        })
        .collect()
}

#[rustler::nif]
fn decode_batch_with_details_normal<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<Vec<DecodeDetailsResult<'a>>> {
    decode_batch_with_details_impl(env, items, bom_mode, error_mode)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_batch_with_details<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<Vec<DecodeDetailsResult<'a>>> {
    decode_batch_with_details_impl(env, items, bom_mode, error_mode)
}

fn decode_batch_with_details_impl<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    bom_mode: Atom,
    error_mode: Atom,
) -> NifResult<Vec<DecodeDetailsResult<'a>>> {
    let bom_mode = parse_bom_mode(bom_mode);
    let error_mode = parse_error_mode(error_mode);

    items
        .into_iter()
        .map(|(binary, enc)| match (bom_mode, error_mode) {
            (Ok(bm), Ok(em)) => decode_with_details_parsed(env, binary.as_slice(), enc, bm, em),
            (Err(reason), _) | (_, Err(reason)) => {
                Ok((atoms::error(), error_binary(env, reason)?, "", false))
            }
        })
        .collect()
}

#[rustler::nif]
fn encode_batch_normal<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    error_mode: Atom,
) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    encode_batch_impl(env, items, error_mode)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_batch<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    error_mode: Atom,
) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    encode_batch_impl(env, items, error_mode)
}

fn encode_batch_impl<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    error_mode: Atom,
) -> NifResult<Vec<(Atom, Binary<'a>)>> {
    let error_mode = parse_error_mode(error_mode);

    items
        .into_iter()
        .map(|(binary, enc)| match error_mode {
            Ok(em) => {
                let (status, payload, _) =
                    encode_with_details_parsed(env, binary.as_slice(), enc, em)?;
                Ok((status, payload))
            }
            Err(reason) => Ok((atoms::error(), error_binary(env, reason)?)),
        })
        .collect()
}

#[rustler::nif]
fn encode_batch_with_details_normal<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    error_mode: Atom,
) -> NifResult<Vec<EncodeDetailsResult<'a>>> {
    encode_batch_with_details_impl(env, items, error_mode)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_batch_with_details<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    error_mode: Atom,
) -> NifResult<Vec<EncodeDetailsResult<'a>>> {
    encode_batch_with_details_impl(env, items, error_mode)
}

fn encode_batch_with_details_impl<'a>(
    env: Env<'a>,
    items: Vec<(Binary, &str)>,
    error_mode: Atom,
) -> NifResult<Vec<EncodeDetailsResult<'a>>> {
    let error_mode = parse_error_mode(error_mode);

    items
        .into_iter()
        .map(|(binary, enc)| match error_mode {
            Ok(em) => encode_with_details_parsed(env, binary.as_slice(), enc, em),
            Err(reason) => Ok((atoms::error(), error_binary(env, reason)?, false)),
        })
        .collect()
}

// =============================================================================
// BOM and Heuristic Detection
// =============================================================================

#[rustler::nif]
fn detect_bom(data: Binary) -> (Atom, &'static str, usize) {
    match Encoding::for_bom(data.as_slice()) {
        Some((encoding, bom_length)) => (atoms::ok(), encoding.name(), bom_length),
        None => (atoms::error(), "no_bom", 0),
    }
}

#[rustler::nif]
fn detect_normal(
    data: Binary,
    tld: Option<&str>,
    allow_utf8: bool,
    allow_iso_2022_jp: bool,
    check_bom: bool,
) -> (Atom, &'static str) {
    detect_impl(
        data.as_slice(),
        tld,
        allow_utf8,
        allow_iso_2022_jp,
        check_bom,
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn detect_dirty(
    data: Binary,
    tld: Option<&str>,
    allow_utf8: bool,
    allow_iso_2022_jp: bool,
    check_bom: bool,
) -> (Atom, &'static str) {
    detect_impl(
        data.as_slice(),
        tld,
        allow_utf8,
        allow_iso_2022_jp,
        check_bom,
    )
}

fn detect_impl(
    input: &[u8],
    tld: Option<&str>,
    allow_utf8: bool,
    allow_iso_2022_jp: bool,
    check_bom: bool,
) -> (Atom, &'static str) {
    let Ok(tld_bytes) = validate_tld(tld) else {
        return (atoms::error(), INVALID_TLD);
    };

    if check_bom {
        if let Some((encoding, _bom_length)) = Encoding::for_bom(input) {
            return (atoms::ok(), encoding.name());
        }
    }

    let iso_mode = if allow_iso_2022_jp {
        Iso2022JpDetection::Allow
    } else {
        Iso2022JpDetection::Deny
    };
    let utf8_mode = if allow_utf8 {
        Utf8Detection::Allow
    } else {
        Utf8Detection::Deny
    };

    let mut detector = EncodingDetector::new(iso_mode);
    detector.feed(input, true);
    let encoding = detector.guess(tld_bytes, utf8_mode);
    (atoms::ok(), encoding.name())
}

#[rustler::nif]
fn detector_new(allow_iso_2022_jp: bool, check_bom: bool) -> ResourceArc<DetectorResource> {
    let iso_mode = if allow_iso_2022_jp {
        Iso2022JpDetection::Allow
    } else {
        Iso2022JpDetection::Deny
    };

    ResourceArc::new(DetectorResource {
        state: Mutex::new(DetectorState {
            detector: EncodingDetector::new(iso_mode),
            check_bom,
            bom_buf: [0; 3],
            bom_len: 0,
            bom_encoding: None,
            finished: false,
        }),
    })
}

#[rustler::nif]
fn detector_feed(
    detector_ref: ResourceArc<DetectorResource>,
    chunk: Binary,
    is_last: bool,
) -> (Atom, bool, &'static str) {
    detector_feed_impl(&detector_ref, chunk.as_slice(), is_last)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn detector_feed_dirty(
    detector_ref: ResourceArc<DetectorResource>,
    chunk: Binary,
    is_last: bool,
) -> (Atom, bool, &'static str) {
    detector_feed_impl(&detector_ref, chunk.as_slice(), is_last)
}

fn detector_feed_impl(
    detector_ref: &DetectorResource,
    input: &[u8],
    is_last: bool,
) -> (Atom, bool, &'static str) {
    let Ok(mut state) = detector_ref.state.lock() else {
        return (atoms::error(), false, LOCK_POISONED);
    };

    match detector_state_feed(&mut state, input, is_last) {
        Ok(non_ascii_seen) => (atoms::ok(), non_ascii_seen, ""),
        Err(reason) => (atoms::error(), false, reason),
    }
}

fn detector_state_feed(
    state: &mut DetectorState,
    input: &[u8],
    is_last: bool,
) -> Result<bool, &'static str> {
    if state.finished {
        return Err(DETECTOR_FINISHED);
    }

    if state.check_bom && state.bom_encoding.is_none() && state.bom_len < 3 && !input.is_empty() {
        let take = (3 - state.bom_len).min(input.len());
        state.bom_buf[state.bom_len..state.bom_len + take].copy_from_slice(&input[..take]);
        state.bom_len += take;
        if let Some((encoding, _)) = Encoding::for_bom(&state.bom_buf[..state.bom_len]) {
            state.bom_encoding = Some(encoding);
        }
    }

    if is_last {
        state.finished = true;
    }

    if state.bom_encoding.is_some() {
        return Ok(true);
    }

    Ok(state.detector.feed(input, is_last))
}

#[rustler::nif]
fn detector_guess(
    detector_ref: ResourceArc<DetectorResource>,
    tld: Option<&str>,
    allow_utf8: bool,
) -> (Atom, &'static str) {
    let Ok(tld_bytes) = validate_tld(tld) else {
        return (atoms::error(), INVALID_TLD);
    };

    let Ok(state) = detector_ref.state.lock() else {
        return (atoms::error(), LOCK_POISONED);
    };

    if let Some(encoding) = state.bom_encoding {
        return (atoms::ok(), encoding.name());
    }

    let utf8_mode = if allow_utf8 {
        Utf8Detection::Allow
    } else {
        Utf8Detection::Deny
    };
    let encoding = state.detector.guess(tld_bytes, utf8_mode);
    (atoms::ok(), encoding.name())
}

fn validate_tld(tld: Option<&str>) -> Result<Option<&[u8]>, &'static str> {
    match tld {
        None => Ok(None),
        Some(label) => {
            if label.is_empty()
                || label
                    .bytes()
                    .any(|b| !b.is_ascii() || b == b'.' || b.is_ascii_uppercase())
            {
                Err(INVALID_TLD)
            } else {
                Ok(Some(label.as_bytes()))
            }
        }
    }
}

// =============================================================================
// Streaming Decoder API
// =============================================================================

#[rustler::nif]
fn decoder_new(
    enc: &str,
    bom_mode: Atom,
    error_mode: Atom,
) -> (Atom, Option<ResourceArc<DecoderResource>>, &'static str) {
    let Ok(bom_mode) = parse_bom_mode(bom_mode) else {
        return (atoms::error(), None, INVALID_BOM_MODE);
    };
    let Ok(error_mode) = parse_error_mode(error_mode) else {
        return (atoms::error(), None, INVALID_ON_ERROR);
    };

    let Some(encoding) = Encoding::for_label(enc.as_bytes()) else {
        return (atoms::error(), None, UNKNOWN_ENCODING);
    };

    let decoder = match bom_mode {
        BomMode::Sniff => encoding.new_decoder(),
        BomMode::Strip => encoding.new_decoder_with_bom_removal(),
        BomMode::Preserve => encoding.new_decoder_without_bom_handling(),
    };

    let resource = ResourceArc::new(DecoderResource {
        state: Mutex::new(DecoderState {
            decoder,
            error_mode,
            finished: false,
        }),
    });
    (atoms::ok(), Some(resource), "")
}

#[rustler::nif]
fn decoder_encoding(decoder_ref: ResourceArc<DecoderResource>) -> (Atom, &'static str) {
    let Ok(state) = decoder_ref.state.lock() else {
        return (atoms::error(), LOCK_POISONED);
    };
    (atoms::ok(), state.decoder.encoding().name())
}

#[rustler::nif]
fn decoder_decode_chunk<'a>(
    env: Env<'a>,
    decoder_ref: ResourceArc<DecoderResource>,
    chunk: Binary,
    is_last: bool,
) -> NifResult<(Atom, Binary<'a>, bool)> {
    decoder_decode_chunk_impl(env, &decoder_ref, chunk.as_slice(), is_last)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decoder_decode_chunk_dirty<'a>(
    env: Env<'a>,
    decoder_ref: ResourceArc<DecoderResource>,
    chunk: Binary,
    is_last: bool,
) -> NifResult<(Atom, Binary<'a>, bool)> {
    decoder_decode_chunk_impl(env, &decoder_ref, chunk.as_slice(), is_last)
}

fn decoder_decode_chunk_impl<'a>(
    env: Env<'a>,
    decoder_ref: &DecoderResource,
    input: &[u8],
    is_last: bool,
) -> NifResult<(Atom, Binary<'a>, bool)> {
    let result = {
        let Ok(mut state) = decoder_ref.state.lock() else {
            return Ok((atoms::error(), error_binary(env, LOCK_POISONED)?, false));
        };
        decoder_state_decode_chunk(&mut state, input, is_last)
    };

    match result {
        Ok((output, had_errors)) => match alloc_binary(env, output.as_bytes()) {
            Ok(bin) => Ok((atoms::ok(), bin, had_errors)),
            Err(reason) => Ok((atoms::error(), error_binary(env, reason)?, false)),
        },
        Err(reason) => Ok((atoms::error(), error_binary(env, reason)?, false)),
    }
}

fn decoder_state_decode_chunk(
    state: &mut DecoderState,
    input: &[u8],
    is_last: bool,
) -> Result<(String, bool), &'static str> {
    if state.finished {
        return Err(DECODER_FINISHED);
    }

    match state.error_mode {
        ErrorMode::Replace => {
            let mut output = allocate_decode_output(&state.decoder, input.len(), false)?;
            let mut remaining = input;
            let mut had_errors = false;

            loop {
                let (result, read, chunk_errors) =
                    state
                        .decoder
                        .decode_to_string(remaining, &mut output, is_last);
                had_errors |= chunk_errors;
                remaining = &remaining[read..];

                match result {
                    CoderResult::InputEmpty => {
                        if is_last {
                            state.finished = true;
                        }
                        return Ok((output, had_errors));
                    }
                    CoderResult::OutputFull => {
                        let extra = state
                            .decoder
                            .max_utf8_buffer_length(remaining.len())
                            .and_then(|n| n.checked_add(16))
                            .ok_or(ALLOCATION_FAILED)?;
                        output.try_reserve(extra).map_err(|_| ALLOCATION_FAILED)?;
                    }
                }
            }
        }
        ErrorMode::Error => {
            let mut output = allocate_decode_output(&state.decoder, input.len(), true)?;
            let mut remaining = input;

            loop {
                let (result, read) = state.decoder.decode_to_string_without_replacement(
                    remaining,
                    &mut output,
                    is_last,
                );
                remaining = &remaining[read..];

                match result {
                    DecoderResult::InputEmpty => {
                        if is_last {
                            state.finished = true;
                        }
                        return Ok((output, false));
                    }
                    DecoderResult::Malformed(_, _) => {
                        state.finished = true;
                        return Err(MALFORMED_INPUT);
                    }
                    DecoderResult::OutputFull => {
                        let extra = state
                            .decoder
                            .max_utf8_buffer_length_without_replacement(remaining.len())
                            .and_then(|n| n.checked_add(16))
                            .ok_or(ALLOCATION_FAILED)?;
                        output.try_reserve(extra).map_err(|_| ALLOCATION_FAILED)?;
                    }
                }
            }
        }
    }
}

fn allocate_decode_output(
    decoder: &encoding_rs::Decoder,
    input_len: usize,
    strict: bool,
) -> Result<String, &'static str> {
    let max_output_len = if strict {
        decoder.max_utf8_buffer_length_without_replacement(input_len)
    } else {
        decoder.max_utf8_buffer_length(input_len)
    }
    .ok_or(ALLOCATION_FAILED)?;

    let mut output = String::new();
    output
        .try_reserve(max_output_len)
        .map_err(|_| ALLOCATION_FAILED)?;
    Ok(output)
}

// =============================================================================
// Streaming Encoder API
// =============================================================================

#[rustler::nif]
fn encoder_new(
    enc: &str,
    error_mode: Atom,
) -> (Atom, Option<ResourceArc<EncoderResource>>, &'static str) {
    let Ok(error_mode) = parse_error_mode(error_mode) else {
        return (atoms::error(), None, INVALID_ON_ERROR);
    };

    let Some(encoding) = Encoding::for_label(enc.as_bytes()) else {
        return (atoms::error(), None, UNKNOWN_ENCODING);
    };

    if !encoder_available(encoding) {
        return (atoms::error(), None, ENCODER_UNAVAILABLE);
    }

    let resource = ResourceArc::new(EncoderResource {
        state: Mutex::new(EncoderState {
            encoder: encoding.new_encoder(),
            error_mode,
            pending_utf8: [0; 4],
            pending_len: 0,
            finished: false,
        }),
    });
    (atoms::ok(), Some(resource), "")
}

#[rustler::nif]
fn encoder_encode_chunk<'a>(
    env: Env<'a>,
    encoder_ref: ResourceArc<EncoderResource>,
    chunk: Binary,
    is_last: bool,
) -> NifResult<(Atom, Binary<'a>, bool)> {
    encoder_encode_chunk_impl(env, &encoder_ref, chunk.as_slice(), is_last)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encoder_encode_chunk_dirty<'a>(
    env: Env<'a>,
    encoder_ref: ResourceArc<EncoderResource>,
    chunk: Binary,
    is_last: bool,
) -> NifResult<(Atom, Binary<'a>, bool)> {
    encoder_encode_chunk_impl(env, &encoder_ref, chunk.as_slice(), is_last)
}

fn encoder_encode_chunk_impl<'a>(
    env: Env<'a>,
    encoder_ref: &EncoderResource,
    input: &[u8],
    is_last: bool,
) -> NifResult<(Atom, Binary<'a>, bool)> {
    let result = {
        let Ok(mut state) = encoder_ref.state.lock() else {
            return Ok((atoms::error(), error_binary(env, LOCK_POISONED)?, false));
        };
        encoder_state_encode_chunk(&mut state, input, is_last)
    };

    match result {
        Ok((output, had_errors)) => match alloc_binary(env, &output) {
            Ok(bin) => Ok((atoms::ok(), bin, had_errors)),
            Err(reason) => Ok((atoms::error(), error_binary(env, reason)?, false)),
        },
        Err(reason) => Ok((atoms::error(), error_binary(env, reason)?, false)),
    }
}

fn encoder_state_encode_chunk(
    state: &mut EncoderState,
    input: &[u8],
    is_last: bool,
) -> Result<(Vec<u8>, bool), &'static str> {
    if state.finished {
        return Err(ENCODER_FINISHED);
    }

    let mut first_buf = [0u8; 4];
    let mut first_len = 0usize;
    let rest_slice: &[u8];

    if state.pending_len > 0 {
        if input.is_empty() {
            if is_last {
                state.finished = true;
                return Err(INVALID_UTF8);
            }
            return Ok((Vec::new(), false));
        }

        let expected = utf8_char_width(state.pending_utf8[0]).ok_or(INVALID_UTF8)?;
        let need = expected - state.pending_len;

        if input.len() < need {
            let new_len = state.pending_len + input.len();
            let mut probe = [0u8; 4];
            probe[..state.pending_len].copy_from_slice(&state.pending_utf8[..state.pending_len]);
            probe[state.pending_len..new_len].copy_from_slice(input);

            match std::str::from_utf8(&probe[..new_len]) {
                Err(err) if err.error_len().is_none() => {
                    if is_last {
                        state.finished = true;
                        return Err(INVALID_UTF8);
                    }
                    state.pending_utf8[state.pending_len..new_len].copy_from_slice(input);
                    state.pending_len = new_len;
                    return Ok((Vec::new(), false));
                }
                _ => {
                    state.finished = true;
                    return Err(INVALID_UTF8);
                }
            }
        }

        first_buf[..state.pending_len].copy_from_slice(&state.pending_utf8[..state.pending_len]);
        first_buf[state.pending_len..expected].copy_from_slice(&input[..need]);
        if std::str::from_utf8(&first_buf[..expected]).is_err() {
            state.finished = true;
            return Err(INVALID_UTF8);
        }
        first_len = expected;
        rest_slice = &input[need..];
    } else {
        rest_slice = input;
    }

    let (rest_valid, new_pending) = match split_valid_utf8(rest_slice, is_last) {
        Ok(parts) => parts,
        Err(reason) => {
            state.finished = true;
            return Err(reason);
        }
    };

    let first_str = if first_len > 0 {
        // Already validated with std::str::from_utf8 above.
        std::str::from_utf8(&first_buf[..first_len]).map_err(|_| INVALID_UTF8)?
    } else {
        ""
    };

    let mut output = Vec::new();
    let mut had_errors = false;

    if !first_str.is_empty() {
        let first_is_last = is_last && rest_valid.is_empty();
        match encode_str_into(
            &mut state.encoder,
            state.error_mode,
            first_str,
            first_is_last,
            &mut output,
        ) {
            Ok(replaced) => had_errors |= replaced,
            Err(reason) => {
                state.finished = true;
                return Err(reason);
            }
        }
    }

    if !rest_valid.is_empty() || (is_last && first_str.is_empty()) {
        match encode_str_into(
            &mut state.encoder,
            state.error_mode,
            rest_valid,
            is_last,
            &mut output,
        ) {
            Ok(replaced) => had_errors |= replaced,
            Err(reason) => {
                state.finished = true;
                return Err(reason);
            }
        }
    }

    state.pending_len = new_pending.len();
    state.pending_utf8[..new_pending.len()].copy_from_slice(new_pending);
    if is_last {
        state.finished = true;
    }

    Ok((output, had_errors))
}

fn utf8_char_width(lead_byte: u8) -> Option<usize> {
    match lead_byte {
        0xC2..=0xDF => Some(2),
        0xE0..=0xEF => Some(3),
        0xF0..=0xF4 => Some(4),
        _ => None,
    }
}

fn split_valid_utf8(input: &[u8], is_last: bool) -> Result<(&str, &[u8]), &'static str> {
    match std::str::from_utf8(input) {
        Ok(valid) => Ok((valid, &[])),
        Err(err) => {
            if !is_last && err.error_len().is_none() {
                let valid_up_to = err.valid_up_to();
                let valid = std::str::from_utf8(&input[..valid_up_to]).map_err(|_| INVALID_UTF8)?;
                Ok((valid, &input[valid_up_to..]))
            } else {
                Err(INVALID_UTF8)
            }
        }
    }
}

fn encode_str_into(
    encoder: &mut encoding_rs::Encoder,
    error_mode: ErrorMode,
    src: &str,
    last: bool,
    output: &mut Vec<u8>,
) -> Result<bool, &'static str> {
    match error_mode {
        ErrorMode::Replace => encode_utf8_replace_into(encoder, src, last, output),
        ErrorMode::Error => {
            encode_utf8_strict_into(encoder, src, last, output)?;
            Ok(false)
        }
    }
}

fn encode_utf8_strict(
    encoder: &mut encoding_rs::Encoder,
    src: &str,
    last: bool,
) -> Result<Vec<u8>, &'static str> {
    let mut output = Vec::new();
    encode_utf8_strict_into(encoder, src, last, &mut output)?;
    Ok(output)
}

fn encode_utf8_strict_into(
    encoder: &mut encoding_rs::Encoder,
    src: &str,
    last: bool,
    output: &mut Vec<u8>,
) -> Result<(), &'static str> {
    let initial = encoder
        .max_buffer_length_from_utf8_without_replacement(src.len())
        .ok_or(ALLOCATION_FAILED)?;
    output.try_reserve(initial).map_err(|_| ALLOCATION_FAILED)?;

    let mut remaining = src;
    loop {
        let (result, read) =
            encoder.encode_from_utf8_to_vec_without_replacement(remaining, output, last);
        remaining = &remaining[read..];

        match result {
            EncoderResult::InputEmpty => return Ok(()),
            EncoderResult::Unmappable(_) => return Err(UNMAPPABLE_CHARACTER),
            EncoderResult::OutputFull => {
                let extra = encoder
                    .max_buffer_length_from_utf8_without_replacement(remaining.len())
                    .and_then(|n| n.checked_add(64))
                    .ok_or(ALLOCATION_FAILED)?;
                output.try_reserve(extra).map_err(|_| ALLOCATION_FAILED)?;
            }
        }
    }
}

fn encode_utf8_replace_into(
    encoder: &mut encoding_rs::Encoder,
    src: &str,
    last: bool,
    output: &mut Vec<u8>,
) -> Result<bool, &'static str> {
    let initial = encoder
        .max_buffer_length_from_utf8_if_no_unmappables(src.len())
        .ok_or(ALLOCATION_FAILED)?;
    output.try_reserve(initial).map_err(|_| ALLOCATION_FAILED)?;

    let mut remaining = src;
    let mut had_errors = false;
    loop {
        let (result, read, replaced) = encoder.encode_from_utf8_to_vec(remaining, output, last);
        had_errors |= replaced;
        remaining = &remaining[read..];

        match result {
            CoderResult::InputEmpty => return Ok(had_errors),
            CoderResult::OutputFull => {
                let extra = encoder
                    .max_buffer_length_from_utf8_if_no_unmappables(remaining.len())
                    .and_then(|n| n.checked_add(64))
                    .ok_or(ALLOCATION_FAILED)?;
                output.try_reserve(extra).map_err(|_| ALLOCATION_FAILED)?;
            }
        }
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn parse_bom_mode(mode: Atom) -> Result<BomMode, &'static str> {
    if mode == atoms::sniff() {
        Ok(BomMode::Sniff)
    } else if mode == atoms::strip() {
        Ok(BomMode::Strip)
    } else if mode == atoms::preserve() {
        Ok(BomMode::Preserve)
    } else {
        Err(INVALID_BOM_MODE)
    }
}

fn parse_error_mode(mode: Atom) -> Result<ErrorMode, &'static str> {
    if mode == atoms::replace() {
        Ok(ErrorMode::Replace)
    } else if mode == atoms::error() {
        Ok(ErrorMode::Error)
    } else {
        Err(INVALID_ON_ERROR)
    }
}

fn alloc_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Result<Binary<'a>, &'static str> {
    let mut bin = OwnedBinary::new(bytes.len()).ok_or(ALLOCATION_FAILED)?;
    // copy_from_slice is infallible here: bin was allocated with bytes.len()
    bin.as_mut_slice().copy_from_slice(bytes);
    Ok(bin.release(env))
}

fn error_binary<'a>(env: Env<'a>, reason: &'static str) -> NifResult<Binary<'a>> {
    let mut bin = OwnedBinary::new(reason.len())
        .ok_or_else(|| rustler::Error::Term(Box::new(ALLOCATION_FAILED)))?;
    bin.as_mut_slice().copy_from_slice(reason.as_bytes());
    Ok(bin.release(env))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_output_allocation_rejects_overflowing_length() {
        let decoder = encoding_rs::UTF_8.new_decoder();

        assert_eq!(
            allocate_decode_output(&decoder, usize::MAX, false),
            Err(ALLOCATION_FAILED)
        );
        assert_eq!(
            allocate_decode_output(&decoder, usize::MAX, true),
            Err(ALLOCATION_FAILED)
        );
    }

    #[test]
    fn only_output_encodings_have_encoders() {
        assert!(encoder_available(encoding_rs::UTF_8));
        assert!(!encoder_available(encoding_rs::UTF_16LE));
        assert!(!encoder_available(encoding_rs::UTF_16BE));
        assert!(!encoder_available(encoding_rs::REPLACEMENT));

        assert_eq!(ALL_ENCODINGS.len(), 40);
        let outputs: Vec<&str> = ALL_ENCODINGS
            .iter()
            .copied()
            .filter(|enc| encoder_available(enc))
            .map(Encoding::name)
            .collect();
        assert_eq!(outputs.len(), 37);
        assert!(!outputs.contains(&"UTF-16LE"));
        assert!(!outputs.contains(&"UTF-16BE"));
        assert!(!outputs.contains(&"replacement"));
    }

    #[test]
    fn decode_core_handles_bom_modes_and_strict_mode() {
        let utf16le_bom_hi = [0xFF, 0xFE, 0x48, 0x00];
        let (text, actual, had_errors) = decode_core(
            &utf16le_bom_hi,
            "windows-1252",
            BomMode::Sniff,
            ErrorMode::Replace,
        )
        .expect("sniff should succeed");
        assert_eq!(text, "H");
        assert_eq!(actual, "UTF-16LE");
        assert!(!had_errors);

        let (text, actual, _) = decode_core(
            &utf16le_bom_hi,
            "windows-1252",
            BomMode::Strip,
            ErrorMode::Replace,
        )
        .expect("strip should keep requested encoding");
        assert_eq!(actual, "windows-1252");
        assert_eq!(text, "ÿþH\u{0000}");

        let utf8_bom = b"\xEF\xBB\xBFhi";
        let (text, _, _) =
            decode_core(utf8_bom, "utf-8", BomMode::Preserve, ErrorMode::Error).expect("preserve");
        assert_eq!(text, "\u{FEFF}hi");

        assert_eq!(
            decode_core(&[0xFF], "utf-8", BomMode::Sniff, ErrorMode::Error),
            Err(MALFORMED_INPUT)
        );
    }

    #[test]
    fn encode_core_validates_utf8_and_strict_unmappables() {
        assert_eq!(
            encode_core(&[0xFF], "windows-1252", ErrorMode::Replace),
            Err(INVALID_UTF8)
        );
        assert_eq!(
            encode_core("🎉".as_bytes(), "windows-1252", ErrorMode::Error),
            Err(UNMAPPABLE_CHARACTER)
        );
        let (encoded, had_errors) =
            encode_core("🎉".as_bytes(), "windows-1252", ErrorMode::Replace).expect("replace");
        assert_eq!(encoded.as_ref(), b"&#127881;");
        assert!(had_errors);
    }

    #[test]
    fn decoder_state_rejects_calls_after_finish() {
        let mut state = DecoderState {
            decoder: encoding_rs::UTF_8.new_decoder(),
            error_mode: ErrorMode::Replace,
            finished: false,
        };
        assert_eq!(
            decoder_state_decode_chunk(&mut state, b"ok", true),
            Ok((String::from("ok"), false))
        );
        assert_eq!(
            decoder_state_decode_chunk(&mut state, b"again", true),
            Err(DECODER_FINISHED)
        );
    }

    #[test]
    fn encoder_state_handles_byte_split_utf8_and_iso_2022_jp_flush() {
        let mut state = EncoderState {
            encoder: encoding_rs::ISO_2022_JP.new_encoder(),
            error_mode: ErrorMode::Replace,
            pending_utf8: [0; 4],
            pending_len: 0,
            finished: false,
        };

        // "あ" in UTF-8 is 3 bytes: E3 81 82. Split one byte at a time.
        let bytes = "あ".as_bytes();
        let (o1, e1) = encoder_state_encode_chunk(&mut state, &bytes[0..1], false).expect("b1");
        let (o2, e2) = encoder_state_encode_chunk(&mut state, &bytes[1..2], false).expect("b2");
        let (o3, e3) = encoder_state_encode_chunk(&mut state, &bytes[2..3], false).expect("b3");
        let (o4, e4) = encoder_state_encode_chunk(&mut state, b"", true).expect("flush");
        assert!(!e1 && !e2 && !e3 && !e4);

        let mut combined = Vec::new();
        combined.extend_from_slice(&o1);
        combined.extend_from_slice(&o2);
        combined.extend_from_slice(&o3);
        combined.extend_from_slice(&o4);
        let (expected, _, _) = encoding_rs::ISO_2022_JP.encode("あ");
        assert_eq!(combined, expected.as_ref());

        assert_eq!(
            encoder_state_encode_chunk(&mut state, b"x", true),
            Err(ENCODER_FINISHED)
        );
    }

    #[test]
    fn encoder_state_handles_dense_unmappable_expansion() {
        let mut state = EncoderState {
            encoder: encoding_rs::WINDOWS_1252.new_encoder(),
            error_mode: ErrorMode::Replace,
            pending_utf8: [0; 4],
            pending_len: 0,
            finished: false,
        };
        let input = "🎉".repeat(200);
        let (out, had_errors) =
            encoder_state_encode_chunk(&mut state, input.as_bytes(), true).expect("replace");
        assert!(had_errors);
        assert_eq!(out, "&#127881;".repeat(200).as_bytes());
    }

    #[test]
    fn detector_state_detects_split_bom_and_rejects_post_finish() {
        let mut state = DetectorState {
            detector: EncodingDetector::new(Iso2022JpDetection::Deny),
            check_bom: true,
            bom_buf: [0; 3],
            bom_len: 0,
            bom_encoding: None,
            finished: false,
        };

        assert_eq!(detector_state_feed(&mut state, &[0xEF], false), Ok(true));
        assert_eq!(detector_state_feed(&mut state, &[0xBB], false), Ok(true));
        assert_eq!(
            detector_state_feed(&mut state, &[0xBF, b'a'], true),
            Ok(true)
        );
        assert_eq!(state.bom_encoding, Some(encoding_rs::UTF_8));
        assert_eq!(
            detector_state_feed(&mut state, b"more", true),
            Err(DETECTOR_FINISHED)
        );
    }

    #[test]
    fn validate_tld_rejects_panicking_inputs() {
        assert_eq!(validate_tld(None), Ok(None));
        assert_eq!(validate_tld(Some("jp")), Ok(Some(&b"jp"[..])));
        assert_eq!(validate_tld(Some("")), Err(INVALID_TLD));
        assert_eq!(validate_tld(Some("JP")), Err(INVALID_TLD));
        assert_eq!(validate_tld(Some(".jp")), Err(INVALID_TLD));
        assert_eq!(validate_tld(Some("co.jp")), Err(INVALID_TLD));
        assert_eq!(validate_tld(Some("日本")), Err(INVALID_TLD));
    }
}

rustler::init!("Elixir.EncodingRs.Native");
