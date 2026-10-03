# Full-source desktop tool projects live below build/, whereas the production
# spec and its Objective-C bridge live at the apple/ root. Source entries are
# already rooted by each generator; Xcode build settings need the same treatment.
module StreamDesktopTransportFixture
  def self.apply(target, root)
    settings = (target['settings'] ||= {})['base'] ||= {}
    header = settings['SWIFT_OBJC_BRIDGING_HEADER']
    if header.is_a?(String) && !header.empty? && !header.include?('$(')
      settings['SWIFT_OBJC_BRIDGING_HEADER'] = File.expand_path(header, root)
    end
  end

  # The SDK peer fixture imports its own bridge header, but compiles exactly the
  # shipping receiver. Newer desktop specs already include both source files.
  def self.include_receiver(target, root)
    sources = target['sources'] ||= []
    ['NativeGuestReceivePrototype/NativeGuestReceiver.swift',
     'NativeGuestReceivePrototype/GuestReceive.cpp'].each do |relative|
      path = File.join(root, relative)
      present = sources.any? do |source|
        value = source.is_a?(String) ? source : source['path']
        next false unless value
        expanded = File.expand_path(value, root)
        expanded == path || expanded == File.dirname(path)
      end
      sources << path unless present
    end
  end
end
