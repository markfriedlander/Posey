// ========== BLOCK 01: MINI-LM EMBEDDER (Layer 2 — Phase B) - START ==========
//
// 2026-05-04 — RAG Layer 2 fix attempt #2.
// Wraps a bundled CoreML build of `sentence-transformers/all-MiniLM-L6-v2`
// (an MTEB-leading retrieval model in its size class). Includes a minimal
// BERT WordPiece tokenizer so we don't need a third-party tokenizer package.
//
// Mark's directive 2026-05-04: "test both NLContextualEmbedding and
// MiniLM/DistilBERT via CoreML or another like model / models, and use
// whichever performs better."
//
// Design:
// - Single shared instance loaded lazily (model cold-start ~50ms).
// - Tokenizer reads `minilm-vocab.txt` once at init (30522 tokens).
// - `embed(_:)` returns 384-dim float vectors as `[Double]` so it
//   plugs into the existing cosine pipeline. L2-normalized at the
//   sentence-transformers layer (the bundled model also has its own
//   pooler_output but we use mean-pooled `last_hidden_state` to match
//   sentence-transformers semantics, which is what the model was
//   trained for).
// - Max sequence length is 128 tokens (matches the bundled mlpackage's
//   shape range). Posey's chunks are 500-1000 chars ≈ 100-250 tokens, so
//   we truncate at 128 — accepting the loss of trailing context for
//   retrieval. Mean-pool over the surviving tokens.

import CoreML
import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// MARK: - Shared instance

@MainActor
public final class MiniLMEmbedder {
    public static let shared = MiniLMEmbedder()

    private var model: MLModel?
    private var tokenizer: BertWordPieceTokenizer?
    private var loadAttempted = false
    private var loadFailureReason: String?

    public let embeddingDim = 384
    public let maxSeqLen = 128

    private init() {}

    /// Lazily loads the model + tokenizer the first time `embed` is
    /// called. Returns nil on permanent failure (model file missing
    /// or tokenizer vocab missing). Errors are logged and remembered
    /// so we don't retry on every chunk.
    private func ensureLoaded() -> Bool {
        if model != nil, tokenizer != nil { return true }
        if loadAttempted, model == nil { return false }
        loadAttempted = true

        guard let mlURL = Bundle.main.url(
            forResource: "MiniLML6v2",
            withExtension: "mlpackage"
        ) ?? Bundle.main.url(
            forResource: "MiniLML6v2",
            withExtension: "mlmodelc"
        ) else {
            loadFailureReason = "MiniLML6v2.mlpackage missing from app bundle"
            dbgLog("[POSEY_MINILM] %@", loadFailureReason!)
            return false
        }
        // Compile mlpackage at runtime if needed.
        let compiledURL: URL
        do {
            if mlURL.pathExtension == "mlmodelc" {
                compiledURL = mlURL
            } else {
                compiledURL = try MLModel.compileModel(at: mlURL)
            }
        } catch {
            loadFailureReason = "MLModel.compileModel failed: \(error)"
            dbgLog("[POSEY_MINILM] %@", loadFailureReason!)
            return false
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all  // Neural Engine where available
        do {
            model = try MLModel(contentsOf: compiledURL, configuration: cfg)
        } catch {
            loadFailureReason = "MLModel init failed: \(error)"
            dbgLog("[POSEY_MINILM] %@", loadFailureReason!)
            return false
        }

        guard let vocabURL = Bundle.main.url(
            forResource: "minilm-vocab",
            withExtension: "txt"
        ) else {
            loadFailureReason = "minilm-vocab.txt missing from app bundle"
            dbgLog("[POSEY_MINILM] %@", loadFailureReason!)
            model = nil
            return false
        }
        do {
            tokenizer = try BertWordPieceTokenizer(vocabURL: vocabURL)
        } catch {
            loadFailureReason = "tokenizer init failed: \(error)"
            dbgLog("[POSEY_MINILM] %@", loadFailureReason!)
            model = nil
            return false
        }
        return true
    }

    /// Embed `text` into a 384-dim vector. Returns nil on failure.
    public func embed(_ text: String) -> [Double]? {
        guard ensureLoaded(), let model, let tokenizer else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = tokenizer.encode(trimmed, maxLength: maxSeqLen)
        guard !tokens.ids.isEmpty else { return nil }

        // Build MLMultiArrays for input_ids and attention_mask, both
        // shape (1, seq_len), int32. seq_len is dynamic in [1, 128].
        let seqLen = tokens.ids.count
        guard let idsArr = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32),
              let maskArr = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32) else {
            return nil
        }
        for i in 0..<seqLen {
            idsArr[i] = NSNumber(value: tokens.ids[i])
            maskArr[i] = NSNumber(value: tokens.mask[i])
        }
        let inputs: MLDictionaryFeatureProvider
        do {
            inputs = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: idsArr),
                "attention_mask": MLFeatureValue(multiArray: maskArr),
            ])
        } catch {
            dbgLog("[POSEY_MINILM] feature provider init failed: %@", "\(error)")
            return nil
        }

        let prediction: MLFeatureProvider
        do {
            prediction = try model.prediction(from: inputs)
        } catch {
            dbgLog("[POSEY_MINILM] prediction failed: %@", "\(error)")
            return nil
        }
        guard let last = prediction.featureValue(for: "last_hidden_state")?.multiArrayValue else {
            return nil
        }
        // last_hidden_state shape is (1, seq_len, 384). Mean-pool with
        // attention mask. Then L2-normalize so cosine == dot.
        let dim = embeddingDim
        var pooled = [Double](repeating: 0, count: dim)
        var liveCount = 0
        // last is shape [1, seqLen, dim]. Index = (0 * seqLen + s) * dim + d.
        for s in 0..<seqLen {
            if tokens.mask[s] == 0 { continue }
            for d in 0..<dim {
                let idx = (s * dim) + d
                pooled[d] += last[idx].doubleValue
            }
            liveCount += 1
        }
        guard liveCount > 0 else { return nil }
        let inv = 1.0 / Double(liveCount)
        for d in 0..<dim { pooled[d] *= inv }
        // L2 normalize.
        var sumSq = 0.0
        for d in 0..<dim { sumSq += pooled[d] * pooled[d] }
        let norm = sqrt(sumSq)
        if norm > 1e-12 {
            let invNorm = 1.0 / norm
            for d in 0..<dim { pooled[d] *= invNorm }
        }
        return pooled
    }

    public var statusDescription: String {
        if model != nil, tokenizer != nil { return "loaded" }
        if let r = loadFailureReason { return "failed: \(r)" }
        if loadAttempted { return "load attempted; not loaded" }
        return "not yet loaded"
    }
}

// ========== BLOCK 01: MINI-LM EMBEDDER (Layer 2 — Phase B) - END ==========


// ========== BLOCK 02: BERT WORDPIECE TOKENIZER - START ==========
//
// Minimal BERT WordPiece tokenizer matching `bert-base-uncased`'s
// behavior:
// 1. BasicTokenizer: NFD normalize, strip accents, split CJK on
//    char boundaries, split punctuation, lowercase.
// 2. WordpieceTokenizer: greedy longest-match-first lookup against
//    the vocabulary, with `##` continuation prefix.
// 3. Wrap with [CLS] / [SEP] specials and produce attention mask.
//
// We do NOT implement: BPE, SentencePiece, Unicode normalization
// beyond NFD+stripAccents, or special-token-aware subword boundaries
// (the all-MiniLM-L6-v2 vocabulary doesn't use any of those).

struct BertWordPieceTokens {
    let ids: [Int32]
    let mask: [Int32]
}

final class BertWordPieceTokenizer {
    let vocab: [String: Int32]
    let unkID: Int32
    let clsID: Int32
    let sepID: Int32
    let padID: Int32
    let doLowerCase: Bool

    init(vocabURL: URL, doLowerCase: Bool = true) throws {
        let raw = try String(contentsOf: vocabURL, encoding: .utf8)
        var v: [String: Int32] = [:]
        var idx: Int32 = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            v[String(line)] = idx
            idx += 1
        }
        self.vocab = v
        self.unkID = v["[UNK]"] ?? 100
        self.clsID = v["[CLS]"] ?? 101
        self.sepID = v["[SEP]"] ?? 102
        self.padID = v["[PAD]"] ?? 0
        self.doLowerCase = doLowerCase
    }

    /// Encode `text` to BERT input ids, capped at `maxLength` tokens
    /// INCLUDING the leading [CLS] and trailing [SEP]. Mask is 1 for
    /// real tokens, 0 for padding (we don't pad here — the model's
    /// shape range is [1, 128] dynamic, so we just truncate).
    func encode(_ text: String, maxLength: Int = 128) -> BertWordPieceTokens {
        // 1. Basic tokenize → list of word tokens.
        let words = basicTokenize(text)
        // 2. Wordpiece each word → list of subword token ids.
        var ids: [Int32] = [clsID]
        let budget = maxLength - 1 // leave room for trailing [SEP]
        for word in words {
            if ids.count >= budget { break }
            let subwords = wordpiece(word)
            for sw in subwords {
                if ids.count >= budget { break }
                ids.append(sw)
            }
        }
        ids.append(sepID)
        let mask = [Int32](repeating: 1, count: ids.count)
        return BertWordPieceTokens(ids: ids, mask: mask)
    }

    // MARK: - Basic tokenizer

    /// Lowercase, strip accents, split punctuation. Whitespace splits
    /// at word boundaries; per-character splits on CJK ideographs and
    /// punctuation.
    private func basicTokenize(_ text: String) -> [String] {
        // Lowercase first to align with cleanup-then-strip-accents.
        let cased = doLowerCase ? text.lowercased() : text
        // Decompose to NFD so accents are separable.
        let decomposed = cased.decomposedStringWithCanonicalMapping
        var cleaned = ""
        for scalar in decomposed.unicodeScalars {
            // Drop combining marks (NFD strips accents this way).
            if scalar.properties.generalCategory == .nonspacingMark { continue }
            // Drop control chars.
            let isControl = scalar.properties.generalCategory == .control
            if isControl { continue }
            // Replace whitespace with single space.
            if scalar.properties.isWhitespace {
                cleaned.append(" ")
                continue
            }
            cleaned.unicodeScalars.append(scalar)
        }
        // Whitespace tokenize, then per-token split punctuation + CJK.
        var output: [String] = []
        for chunk in cleaned.split(separator: " ", omittingEmptySubsequences: true) {
            output.append(contentsOf: splitOnPunctAndCJK(String(chunk)))
        }
        return output
    }

    private func splitOnPunctAndCJK(_ token: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for scalar in token.unicodeScalars {
            if isPunctuation(scalar) || isCJK(scalar) {
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                pieces.append(String(scalar))
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let cp = scalar.value
        // BERT's punctuation rule: ASCII punctuation OR Unicode P*.
        if (cp >= 33 && cp <= 47) || (cp >= 58 && cp <= 64)
           || (cp >= 91 && cp <= 96) || (cp >= 123 && cp <= 126) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let cp = scalar.value
        return (cp >= 0x4E00 && cp <= 0x9FFF) // CJK Unified
            || (cp >= 0x3400 && cp <= 0x4DBF) // CJK Extension A
            || (cp >= 0x20000 && cp <= 0x2A6DF) // CJK Ext B
            || (cp >= 0x2A700 && cp <= 0x2B73F)
            || (cp >= 0x2B740 && cp <= 0x2B81F)
            || (cp >= 0x2B820 && cp <= 0x2CEAF)
            || (cp >= 0xF900 && cp <= 0xFAFF)  // CJK Compat
            || (cp >= 0x2F800 && cp <= 0x2FA1F)
    }

    // MARK: - WordPiece

    /// Greedy longest-match WordPiece. Returns subword ids; falls back
    /// to [UNK] when no vocab match exists for any prefix of the
    /// remaining substring. Continuation pieces use the `##` prefix.
    private func wordpiece(_ word: String) -> [Int32] {
        if word.count > 100 { return [unkID] } // bert spec
        let chars = Array(word)
        var subTokens: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int32? = nil
            while start < end {
                var piece = String(chars[start..<end])
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] {
                    found = id
                    break
                }
                end -= 1
            }
            guard let id = found else {
                return [unkID]
            }
            subTokens.append(id)
            start = end
        }
        return subTokens.isEmpty ? [unkID] : subTokens
    }
}

// ========== BLOCK 02: BERT WORDPIECE TOKENIZER - END ==========
