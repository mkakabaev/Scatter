import SwiftUI
import AppKit

/// Installs a single local key monitor while the view is alive.
struct KeyMonitor: NSViewRepresentable {
    var handler: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(handler: handler)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var handler: ((NSEvent) -> NSEvent?)?
        private var monitor: Any?

        func install(handler: @escaping (NSEvent) -> NSEvent?) {
            self.handler = handler
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handler?(event) ?? event
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            remove()
        }
    }
}
