# Secondary canvas and rundown operation names (#90)

Source review at `cd3bba32c7056a24509e97d6f902b6fa2ea4fd04` found four secondary-canvas safe-zone sliders whose edge names were separate sibling text, with no control label or accessibility value. The rundown's earlier/later/remove buttons were icons without cue-specific operation names. Each secondary layer's Follow Program button also omitted its target.

The safe-zone sliders now declare native labels naming the secondary canvas and edge, with their current value expressed as a percentage. The new formatter runs only inside the existing 0–40% range, so invalid/nonfinite values report unavailable without integer conversion. Their labels are visually hidden, preserving the existing row layout and visible readings. Follow Program identifies its layer and canvas. Rundown operation names include the cue position and scene name, distinguishing repeated uses of a scene; missing scenes retain the existing Missing scene description. Native disabled boundaries remain unchanged.

Bindings, callbacks, actions, ranges, increments, view identity and layout are unchanged. Existing buttons and sliders provide the native interaction path; no custom input, adjustment action, shortcut or focus policy was added.

Both actual Swift files passed `xcrun swiftc -frontend -parse` and `git diff --check`. No implementation-mirroring test or native build was added. The parent combined application build remains the integration typecheck.

No window, AX request, keyboard event, source capture, plugin, playback, permission or system operation was performed. Native accessibility/VoiceOver delivery, keyboard traversal, mounted layout and visual contrast remain unqualified. Original #90 remains open.
