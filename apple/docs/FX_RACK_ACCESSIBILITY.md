# Mixer Effects rack operation names (#90)

The source audit at `c90de17c24bb6265e9796582be39be0e6e350b0b` found that the shared native-effects row constructed twelve sliders without a control label or accessibility value. A separate sibling `Text` showed the parameter name. Gate and compressor controls both used names such as Threshold, requiring section and channel context. The generic Audio Unit editor also constructed its continuous-parameter slider without a control label. Plugin edit/reorder/remove buttons used icons without operation names, and section Reset buttons did not identify their section.

The existing sliders now use native initializer labels, visually hidden to retain the current row layout. Native effect names include the channel, section and parameter; values reuse the existing Hz, dB, millisecond and ratio formatters only when within the control's range. The hosted parameter slider identifies its plugin and parameter, checks and formats one captured value, and retains the existing optional plugin-reported unit name. No unit is invented when the plugin provides none. Existing section toggles and Reset buttons name their channel and section; hosted-slot controls name the plugin, slot position and channel.

Bindings, actions, ranges, steps, disablement, view identity, visible numeric readings and polling are unchanged. The controls remain native sliders, buttons and toggles; no custom input, adjustment action, shortcut or focus policy was added. Existing parameter writes still use the dispatcher or the same Audio Unit setter.

The actual changed Swift source passed `xcrun swiftc -frontend -parse apple/StreamMac/ChannelFXRackView.swift` and `git diff --check`. No implementation-mirroring tests or native builds were added; the parent combined application build remains the integration typecheck.

No plugin was launched or inspected, and no window, AX request, keyboard input, trust, capture, playback or system operation was performed. Native accessibility/VoiceOver delivery, keyboard traversal, full-window layout and contrast remain unqualified. Original #90 remains open.
