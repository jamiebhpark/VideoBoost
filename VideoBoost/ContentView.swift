import SwiftUI
import AVKit

struct ContentView: View {
    @State private var showVideoPicker = false
    @State private var inputVideoURL: URL?
    @State private var outputVideoURL: URL?
    
    var body: some View {
        VStack {
            Text("VideoBoost")
                .font(.largeTitle)
                .padding()
            
            Button(action: {
                showVideoPicker = true
            }) {
                Text("Select Video")
                    .font(.title)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding()
            
            if let inputVideoURL = inputVideoURL {
                VideoPlayer(player: AVPlayer(url: inputVideoURL))
                    .frame(height: 300)
                
                Button(action: {
                    upscaleVideo(inputVideoURL: inputVideoURL)
                }) {
                    Text("Upscale Video")
                        .font(.title)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()
            }
            
            if let outputVideoURL = outputVideoURL {
                Text("Upscaled Video:")
                    .font(.headline)
                    .padding()
                VideoPlayer(player: AVPlayer(url: outputVideoURL))
                    .frame(height: 300)
            }
        }
        .sheet(isPresented: $showVideoPicker) {
            VideoPicker(videoURL: $inputVideoURL)
        }
    }
    
    func upscaleVideo(inputVideoURL: URL) {
        guard let videoUpscaler = VideoUpscaler() else {
            print("Failed to initialize VideoUpscaler")
            return
        }
        
        videoUpscaler.upscaleVideo(inputURL: inputVideoURL) { outputURL in
            DispatchQueue.main.async {
                self.outputVideoURL = outputURL
            }
        }
    }
}

struct VideoPicker: UIViewControllerRepresentable {
    @Binding var videoURL: URL?
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: VideoPicker
        
        init(parent: VideoPicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let url = info[.mediaURL] as? URL {
                parent.videoURL = url
            }
            picker.dismiss(animated: true)
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.mediaTypes = ["public.movie"]
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}
