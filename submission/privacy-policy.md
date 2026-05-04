# Posey — Privacy Policy

_Last updated: May 4, 2026_

Posey is a personal reading companion that runs entirely on your
device. This policy describes what data Posey handles and how.

## What Posey does NOT do

- **No accounts.** Posey does not require sign-in, sign-up, or any
  identifier tied to you.
- **No analytics.** Posey does not collect usage statistics,
  crash telemetry, advertising identifiers, or any behavioural
  data.
- **No third-party services.** Posey does not send data to
  third-party AI providers, ad networks, analytics platforms,
  or any external service.
- **No network requests in the core path.** The reader, the text-
  to-speech engine, the note-taking surface, and the optional
  Ask Posey assistant all run locally. Posey does not phone home.

## What Posey does on your device

- **Stores your imported documents** in the app's private
  on-device storage (a SQLite database in the app's sandbox).
  Only Posey can read this data; iOS prevents other apps from
  accessing it. Documents you delete from Posey are removed from
  this store.
- **Stores your notes, bookmarks, reading positions, and Ask
  Posey conversations** in the same on-device database. These
  are never transmitted off-device.
- **Generates spoken audio** using Apple's on-device speech
  synthesizer. The text you import is read aloud by macOS/iOS;
  no audio is sent over the network.
- **Optionally answers questions about your documents** using
  Apple Intelligence (Apple Foundation Models). When you use the
  Ask Posey feature, your question and relevant excerpts of the
  document are processed by Apple's on-device language model.
  This processing happens on your device. See Apple's privacy
  policy for Apple Intelligence:
  <https://www.apple.com/privacy/>.

## Optional features that involve data leaving your device

These are explicit opt-in actions you initiate; nothing happens
automatically.

- **Sharing.** When you tap the share button on an exported
  notes file or audio export, iOS opens the standard system
  share sheet. Whatever destination you pick (Mail, Messages,
  Files, AirDrop, a third-party app, etc.) receives that one
  file. Posey does not see the destination or what happens to
  the file afterward.
- **Saving to Files.** When you save an export to the Files app,
  iOS handles the file write. The file is in iCloud Drive only
  if you put it there.
- **Motion permission (optional).** Posey's "Auto" reading-style
  preference uses CoreMotion to detect whether you're walking
  or stationary so the layout can adjust. Motion data never
  leaves your device, and the permission is asked only when you
  explicitly choose Auto in Reading Style preferences.

## What Posey requests permission for

- **Document import** — handled through the iOS document picker
  (you select files; Posey does not browse your device).
- **Motion data** — only when you choose Auto reading style
  (see above). You can revoke this in iOS Settings > Posey.
- **Local network** — not used in production. (A development-only
  diagnostic API exists in debug builds and is compiled out of
  release builds.)

## Children's privacy

Posey does not collect any personal information from anyone,
including children under 13. The app is suitable for any age
that can read.

## Changes to this policy

If this policy changes materially, the new version will be
published at the same URL with an updated "Last updated" date.

## Contact

Questions about this policy can be sent to the email address
listed on the App Store page.
