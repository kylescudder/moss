import AVFoundation
import PhotosUI
import SwiftUI

struct PlanPhotosSection: View {
    @Binding var photos: [PlanPhoto]
    @Binding var isImporting: Bool
    @State private var selection: PhotosPickerItem?
    @Binding var showCamera: Bool
    @State private var errorMessage: String?
    @Binding var selectedPhoto: PlanPhoto?

    var body: some View {
        Section {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                HStack {
                    Button { selectedPhoto = photo } label: {
                        PlanPhotoThumbnail(photo: photo)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View photo \(index + 1)")
                    Spacer()
                    Button(role: .destructive) { photos.removeAll { $0.id == photo.id } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove photo \(index + 1)")
                    .disabled(isImporting)
                }
            }
            if photos.count < PlanPhoto.maximumCount {
                PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                    Label("Choose from photo library", systemImage: "photo.on.rectangle")
                }
                .disabled(isImporting)
                Button("Take a photo", systemImage: "camera") {
                    Task { await openCamera() }
                }
                .disabled(isImporting || !UIImagePickerController.isSourceTypeAvailable(.camera))
            }
            if isImporting { ProgressView("Adding photo…") }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        } header: {
            Text("Photos (\(photos.count)/\(PlanPhoto.maximumCount))")
        } footer: {
            Text("Add up to three photos. Images are resized for offline access and shared with anyone who can view this trip. Save the plan to keep your changes.")
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            isImporting = true
            Task {
                defer { isImporting = false; selection = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw PlanPhoto.PhotoError.invalidImage
                    }
                    try await append(data)
                } catch {
                    errorMessage = "This photo couldn't be loaded. Download it to your device or choose another image."
                }
            }
        }

    }

    @MainActor private func append(_ data: Data) async throws {
        let photo = try await Task.detached(priority: .userInitiated) { try PlanPhoto.prepare(data) }.value
        guard photos.count < PlanPhoto.maximumCount else { return }
        photos.append(photo)
        errorMessage = nil
    }

    @MainActor private func openCamera() async {
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        if allowed { showCamera = true }
        else { errorMessage = "Camera access is off. Enable it in Settings to take a photo, or choose one from your photo library." }
    }
}

struct PlanPhotoThumbnail: View {
    let photo: PlanPhoto
    var body: some View {
        if let image = UIImage(data: photo.jpeg) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
    }
}

struct PlanPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photo: PlanPhoto
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let image = UIImage(data: photo.jpeg) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: geometry.size.width * min(max(zoom * magnification, 1), 4))
                            .accessibilityLabel("Plan photo. Pinch to zoom.")
                    }
                }
                .gesture(MagnifyGesture()
                    .updating($magnification) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 1), 4) })
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct PlanCameraPicker: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            completion(info[.originalImage] as? UIImage)
        }
    }
}
