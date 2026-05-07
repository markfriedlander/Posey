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
        // Device's preferred locale in BCP-47 form (e.g. "en-US"). Used to sort
        // the matching locale variant to the top within each quality tier.
        let preferredLocale = Locale.preferredLanguages.first ?? "en-US"

        var built: [Group] = grouped.map { code, voices in
            let sorted = voices.sorted {
                if $0.qualitySortIndex != $1.qualitySortIndex {
                    return $0.qualitySortIndex < $1.qualitySortIndex
                }
                // Within the same quality tier, device locale comes first.
                if $0.language == preferredLocale { return true }
                if $1.language == preferredLocale { return false }
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
/// Defaults to the device's current language. "Show all languages" expands the full list.
/// Presented as a NavigationLink destination from ReaderPreferencesSheet.
struct VoicePickerView: View {
    @Binding var selectedIdentifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var showAllLanguages = false

    private let voiceList = VoiceList()

    /// Language code prefix for the device's current locale (e.g. "en" from "en-US").
    private var currentLanguageCode: String {
        let full = AVSpeechSynthesisVoice.currentLanguageCode()
        return String(full.split(separator: "-").first ?? "en")
    }

    private var visibleGroups: [VoiceList.Group] {
        // 2026-05-07 (parity #5): test-only override to force the
        // empty-state code path regardless of installed voices. Lets
        // the antenna's OPEN_VOICE_PICKER_SHEET verb verify the
        // empty-state copy on devices that have voices installed for
        // the current language. Set the env var when launching the
        // app for testing; without it, normal behavior applies.
        if ProcessInfo.processInfo.environment["POSEY_DEBUG_VOICE_PICKER_EMPTY"] == "1" {
            return []
        }
        guard !showAllLanguages else { return voiceList.groups }
        return voiceList.groups.filter { $0.languageCode == currentLanguageCode }
    }

    var body: some View {
        List {
            if visibleGroups.isEmpty {
                // 2026-05-07 (parity #5): real empty state when no
                // voices are available for the current language and
                // the user hasn't expanded to all languages yet.
                // The "Show all languages" button below this section
                // is the natural next step.
                Section {
                    Text("No voices for your current language are downloaded. Tap \"Show all languages\" below, or download voices in Settings → Accessibility → Spoken Content → Voices.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .accessibilityIdentifier("voicePicker.empty")
                }
            }

            ForEach(visibleGroups) { group in
                Section(group.languageDisplayName) {
                    ForEach(group.voices) { option in
                        voiceRow(option)
                    }
                }
            }

            Section {
                if !showAllLanguages {
                    Button("Show all languages") {
                        showAllLanguages = true
                    }
                }
                Text("Only voices downloaded to your device are listed. To download higher-quality voices, go to Settings → Accessibility → Spoken Content → Voices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    HStack(spacing: 4) {
                        Text(option.qualityLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(qualityColor(for: option.voice.quality))
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(option.language)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if option.id == selectedIdentifier {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func qualityColor(for quality: AVSpeechSynthesisVoiceQuality) -> Color {
        switch quality {
        case .premium:  return Color.accentColor
        case .enhanced: return Color.secondary
        default:        return Color.secondary.opacity(0.6)
        }
    }
}

// ========== BLOCK 03: VOICE PICKER VIEW - END ==========
