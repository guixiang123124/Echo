import Foundation

/// Cross-process notification center using Darwin (CFNotificationCenter).
/// Used for signaling between the main app and keyboard extension.
/// Darwin notifications carry no payload — data is exchanged via AppGroupBridge.
public final class DarwinNotificationCenter: @unchecked Sendable {
   public static let shared = DarwinNotificationCenter()

   /// Well-known notification names for keyboard ↔ app IPC.
   public enum Name: String, Sendable, CaseIterable {
       /// Keyboard → App: start a dictation session
       case dictationStart = "com.echo.dictation.start"
       /// Keyboard → App: stop the current dictation session
       case dictationStop = "com.echo.dictation.stop"
       /// App → Keyboard: new streaming partial text is ready to read
       case transcriptionReady = "com.echo.transcription.ready"
       /// App → Keyboard: periodic heartbeat while session is alive
       case heartbeat = "com.echo.dictation.heartbeat"
       /// App → Keyboard: dictation state changed (read from bridge)
       case stateChanged = "com.echo.dictation.stateChanged"
   }

   /// Opaque token returned by `observe(_:handler:)`. Remove with `removeObservation(_:)`.
   public final class ObservationToken: @unchecked Sendable {
       let name: Name
       let id: UUID

       fileprivate init(name: Name, id: UUID) {
           self.name = name
           self.id = id
       }
   }

   private let center: CFNotificationCenter
   private let lock = NSLock()
   private var handlers: [String: [(id: UUID, handler: @Sendable () -> Void)]] = [:]

   private init() {
       self.center = CFNotificationCenterGetDarwinNotifyCenter()
   }

   // MARK: - Post

   /// Post a Darwin notification (cross-process, no payload).
   public func post(_ name: Name) {
       CFNotificationCenterPostNotification(
           center,
           CFNotificationName(rawValue: name.rawValue as CFString),
           nil,
           nil,
           true // deliver immediately, even if observer app is suspended
       )
   }

   // MARK: - Observe

   /// Register to observe a Darwin notification. Returns an `ObservationToken`
   /// that must be retained. Call `removeObservation(_:)` to stop observing.
   @discardableResult
   public func observe(_ name: Name, handler: @escaping @Sendable () -> Void) -> ObservationToken {
       let tokenId = UUID()
       let token = ObservationToken(name: name, id: tokenId)

       lock.lock()
       let nameKey = name.rawValue
       let isFirstForName = handlers[nameKey] == nil || handlers[nameKey]!.isEmpty
       if handlers[nameKey] == nil {
           handlers[nameKey] = []
       }
       handlers[nameKey]!.append((id: tokenId, handler: handler))
       lock.unlock()

       if isFirstForName {
           registerDarwinObserver(for: name)
       }

       return token
   }

   /// Remove a previously registered observation.
   public func removeObservation(_ token: ObservationToken) {
       let nameKey = token.name.rawValue

       lock.lock()
       handlers[nameKey]?.removeAll { $0.id == token.id }
       let isEmpty = handlers[nameKey]?.isEmpty ?? true
       lock.unlock()

       if isEmpty {
           unregisterDarwinObserver(for: token.name)
       }
   }

   /// Remove all observations (e.g. on deactivate).
   public func removeAllObservations() {
       lock.lock()
       let allNames = handlers.keys.compactMap { Name(rawValue: $0) }
       handlers.removeAll()
       lock.unlock()

       for name in allNames {
           unregisterDarwinObserver(for: name)
       }
   }

   // MARK: - Private

   private func registerDarwinObserver(for name: Name) {
       let rawName = name.rawValue as CFString
       // Use Unmanaged to pass `self` as observer context.
       let observer = Unmanaged.passUnretained(self).toOpaque()

       CFNotificationCenterAddObserver(
           center,
           observer,
           { _, observer, cfName, _, _ in
               guard let observer, let cfName else { return }
               let center = Unmanaged<DarwinNotificationCenter>
                   .fromOpaque(observer)
                   .takeUnretainedValue()
               let nameString = cfName.rawValue as String
               center.dispatchHandlers(for: nameString)
           },
           rawName,
           nil,
           .deliverImmediately
       )
   }

   private func unregisterDarwinObserver(for name: Name) {
       let rawName = name.rawValue as CFString
       let observer = Unmanaged.passUnretained(self).toOpaque()
       CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(rawName), nil)
   }

   private func dispatchHandlers(for nameString: String) {
       lock.lock()
       let entries = handlers[nameString] ?? []
       lock.unlock()

       for entry in entries {
           entry.handler()
       }
   }
}
