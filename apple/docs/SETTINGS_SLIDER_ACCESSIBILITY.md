# Settings slider semantic labels (#90)

Source audit at `ea3c834613ff6b9c85d4383ba1c85d644402ca50` found four unlabeled slider construction sites in `SettingsView.swift`. Each displayed its title in a separate sibling `Text`, but the slider itself had neither an initializer label nor an explicit accessibility name. This affected Maximum Bitrate, microphone volume, per-channel/source audio and video delays, and all five music ducking parameters.

The actual sliders now declare operation labels through their native SwiftUI initializer. Duplicate visual labels are hidden, retaining the existing visible row title and numeric reading. Spoken values include megabits per second, volume percent or Muted, delay milliseconds or Off, and the existing ducking dB/millisecond formats. Delay values avoid integer conversion; nonfinite delay values and out-of-range ducking values report unavailable. Volume reuses the existing overflow-safe `StudioGainAccessibility` formatter. The existing icon-only close button also has an explicit Close settings accessibility label.

Bindings, ranges, steps, dispatch calls, enablement, visible numeric readings and view identity are unchanged. No new shortcuts, focus changes, polling or announcements were added. This directly addresses original #90's accessible slider and named action requirement; it does not close the issue.

## Verification scope

The actual changed Swift source passed `xcrun swiftc -frontend -parse apple/StreamMac/SettingsView.swift` and `git diff --check`. Source review confirms all four slider construction sites now have operation labels and unit-bearing values. No new test was added for these semantic modifiers. The parent combined universal application build remains the integration typecheck.

No native window, accessibility tree walk, keyboard event, VoiceOver session, capture, permission or preference operation was run. Mounted semantic delivery, keyboard operation, spoken output, visual contrast and full-window acceptance remain unqualified by this source-only change. Prior locked-session qualification limits are unchanged.
