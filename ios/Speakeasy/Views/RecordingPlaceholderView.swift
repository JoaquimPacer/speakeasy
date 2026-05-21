import SwiftUI

struct RecordingPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedQuality: DeliveryVideoQuality = .compact480p

    let contact: Contact?

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black)
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.82))
                    Text("Camera pipeline pending")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxWidth: 360)
            .padding(.top)

            Picker("Quality", selection: $selectedQuality) {
                ForEach(DeliveryVideoQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            HStack(spacing: 18) {
                Button {
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Switch camera")
                .disabled(true)

                Button {
                } label: {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Record video")
                .disabled(true)

                Button {
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Send video")
                .disabled(true)
            }

            Spacer()
        }
        .padding()
        .navigationTitle(contact.map { "Record for \($0.displayName)" } ?? "Record")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RecordingPlaceholderView(contact: PreviewData.sample.contacts[0])
    }
}

