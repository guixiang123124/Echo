import SwiftUI
import EchoCore

/// Mini overlay shown when background dictation is active and the user
/// is looking at the main app (rather than the keyboard's host app).
struct BackgroundDictationOverlay: View {
   @ObservedObject var service: BackgroundDictationService

   var body: some View {
       HStack(spacing: 10) {
           statusIndicator
           statusText
           Spacer()
           stopButton
       }
       .padding(.horizontal, 16)
       .padding(.vertical, 10)
       .background(
           RoundedRectangle(cornerRadius: 14, style: .continuous)
               .fill(.ultraThinMaterial)
               .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
       )
       .padding(.horizontal, 16)
       .padding(.top, 8)
   }

   @ViewBuilder
   private var statusIndicator: some View {
       switch service.state {
       case .recording:
           Circle()
               .fill(Color.red)
               .frame(width: 10, height: 10)
               .overlay(
                   Circle()
                       .fill(Color.red.opacity(0.4))
                       .frame(width: 18, height: 18)
                       .scaleEffect(pulseScale)
                       .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseScale)
               )
       case .transcribing, .finalizing:
           ProgressView()
               .scaleEffect(0.7)
               .frame(width: 10, height: 10)
       case .error:
           Image(systemName: "exclamationmark.triangle.fill")
               .font(.system(size: 12))
               .foregroundStyle(.yellow)
       case .idle:
           EmptyView()
       }
   }

   @ViewBuilder
   private var statusText: some View {
       VStack(alignment: .leading, spacing: 2) {
           Text(statusTitle)
               .font(.system(size: 13, weight: .semibold))
               .foregroundStyle(.primary)

           if !service.latestPartialText.isEmpty {
               Text(service.latestPartialText)
                   .font(.system(size: 11))
                   .foregroundStyle(.secondary)
                   .lineLimit(1)
                   .truncationMode(.tail)
           }
       }
   }

   private var stopButton: some View {
       Button {
           Task { await service.stopDictation() }
       } label: {
           Image(systemName: "stop.fill")
               .font(.system(size: 12, weight: .semibold))
               .foregroundStyle(.white)
               .frame(width: 28, height: 28)
               .background(Circle().fill(Color.red))
       }
   }

   private var statusTitle: String {
       switch service.state {
       case .recording:
           return "Recording..."
       case .transcribing:
           return "Transcribing..."
       case .finalizing:
           return "Finalizing..."
       case .error(let msg):
           return "Error: \(msg)"
       case .idle:
           return "Idle"
       }
   }

   @State private var pulseScale: CGFloat = 1.0
}
