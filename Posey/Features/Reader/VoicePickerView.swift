import AVFoundation
import SwiftUI

// ========== BLOCK 01: VOICE OPTION MODEL - START ==========

/// A single voice available on the device, with display-ready labels.
struct VoiceOption: Identifiable {
    let voice: AVSpeechSynthesisVoice

    var id: String { voice.identifier }
    var name: String { voice.name }
    var language: String { voice.language }

    var qualityLabel: String {
        switch voice.quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Standard"
        }
    }

    /// Sort index: lower = higher quality (Premium first).
    var qualitySortIndex: Int {
        switch voice.quality {
        case .premium:  return 0
        case .enhanced: return 1
        default:        return 2
        }
    }

    /// BCP-47 language code, e.g. "en" from "en-US".
    var languageCode: String {
        String(voice.language.split(separator: "-").first ?? "en")
    }

    /// Human-readable language name using the current locale.
    var languageDisplayName: String {
        Locale.current.localizedString(forLanguageCode: languageCode)
            ?? languageCode.uppercased()
    }

    /// One-line label: "Ava · Premium · en-US"
    var fullLabel: String { "\(name) · \(qualityLabel) · \(language)" }
}

// ========== BLOCK 01: VOICE OPTION MODEL - END ==========

// ========== BLOCK 02: VOICE LIST DATA - START ==========

/// Groups and sorts all voices available on the device.
///
/// Grouping: language (alphabetical, English first) →
///           quality tier (Premium → Enhanced → Standard) →
///           locale variant (alphabetical within tier).
struct VoiceList {
    struct Group: Identifiable {
        var id: String { languageCode }
        let languageCode: String
        let languageDisplayName: String
        let voices: [VoiceOption]
    }

    let groups: [Group]

    init() {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
            .map { VoiceOption(voice: $0) }

        let grouped = Dictionary(grouping: allVoices, by: \.languageCode)

        var built: [Group] = grouped.map { code, voices in
            let sorted = voices.sorted {
                if $0.qualitySortIndex != $1.qualitySortIndex {
                    return $0.qualitySortIndex < $1.qualitySortIndex
                }
                return $0.language < $1.language
            }
            let displayName = sorted.first?.languageDisplayName ?? code.uppercased()
            return Group(languageCode: code, languageDisplayName: displayName, voices: sorted)
        }

        // Sort groups alphabetically, English first.
        built.sort {
            if $0.languageCode == "en" { return true }
            if $1.languageCode == "en" { return false }
            return $0.languageDisplayName < $1.languageDisplayName
        }

        groups = built
    }
}

// ========== BLOCK 02: VOICE LIST DATA - END ==========

// ========== BLOCK 03: VOICE PICKER VIEW - START ==========

/// Full-screen voice selection list, grouped by language then quality tier.
/// Presented as a NavigationLink destination from ReaderPreferencesSheet.
struct VoicePickerView: View {
    @Binding var selectedIdentifier: String
    @Environment(\.dismiss) private var dismiss

    private let voiceList = VoiceList()

    var body: some View {
        List {
            ForEach(voiceList.groups) { group in
                Section(group.languageDisplayName) {
                    ForEach(group.voices) { option in
                        voiceRow(option)
                    }
                }
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func voiceRow(_ option: VoiceOption) -> some View {
        Button {
            selectedIdentifier = option.id
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .foregroundStyle(.primary)
                    Text("\(option.qualityLabel) · \(option.language)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if option.id == selectedIdentifier {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

// ========== BLOCK 03: VOICE PICKER VIEW - END ==========
