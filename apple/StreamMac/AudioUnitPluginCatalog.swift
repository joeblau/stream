import AVFAudio
import Foundation
import StreamCore

/// A11 (issue #123): one installed Audio Unit effect, as shown in the FX
/// rack's "Add Audio Unit" picker — manufacturer and name from the system's
/// component registry, identity as the persistable `AudioUnitComponentID`.
struct AudioUnitPluginInfo: Identifiable, Hashable {
    let component: AudioUnitComponentID
    var id: AudioUnitComponentID { component }
    /// The registry name with the redundant "Manufacturer: " prefix dropped
    /// (the rack groups/sorts by manufacturer separately).
    var shortName: String {
        let name = component.displayName
        if let colon = name.firstIndex(of: ":") {
            return name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return name
    }
    var manufacturerName: String {
        let name = component.displayName
        if let colon = name.firstIndex(of: ":") {
            return String(name[name.startIndex..<colon])
        }
        return ""
    }
}

/// A11 (issue #123): discovery of the Audio Unit effects registered with the
/// system (`AVAudioUnitComponentManager`, which wraps AudioComponentManager /
/// AudioComponentFindNext). Effects ('aufx') only — generators/instruments
/// have no input bus to sit on a channel insert. Enumeration works under the
/// app sandbox; LOADING a third-party component in-process is what requires
/// the `audio-unit-host` temporary-exception entitlement (see
/// StreamMac.entitlements and project.yml).
enum AudioUnitPluginCatalog {

    /// Every registered effect component, Apple-native included, sorted by
    /// manufacturer then name for the picker. Reads the live registry, so a
    /// plugin installed while the rack is open appears on the next open.
    static func installedEffects() -> [AudioUnitPluginInfo] {
        let predicate = NSPredicate(format: "typeName == %@", AVAudioUnitTypeEffect)
        return AVAudioUnitComponentManager.shared()
            .components(matching: predicate)
            .map { component in
                AudioUnitPluginInfo(component: AudioUnitComponentID(
                    description: component.audioComponentDescription,
                    displayName: component.name))
            }
            .sorted {
                ($0.manufacturerName, $0.shortName) < ($1.manufacturerName, $1.shortName)
            }
    }
}
