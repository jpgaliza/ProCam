import SwiftUI

/// Fullscreen camera screen: live graded viewfinder + minimalist bottom control bar.
struct CameraView: View {

    @State private var model = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.phase {
            case .cameraDenied:
                PermissionView(
                    title: "Camera Access Needed",
                    message: "ProCam needs the camera to capture RAW photos. Enable access in Settings.",
                    action: model.openSettings
                )
            case .failed(let message):
                PermissionView(title: "Camera Unavailable", message: message, action: nil)
            default:
                cameraContent
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, newPhase in model.handleScenePhase(newPhase) }
    }

    private var cameraContent: some View {
        ZStack {
            GeometryReader { geometry in
                MetalPreviewView(renderer: model.camera.previewRenderer)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            model.focus(at: value.location, in: geometry.size)
                        }
                    )
                    .overlay(alignment: .topLeading) {
                        if let point = model.focusPoint {
                            FocusIndicator(trigger: model.focusTrigger)
                                .position(point)
                        }
                    }
            }
            .ignoresSafeArea()

            ShutterBlink(trigger: model.shutterTrigger)

            VStack(spacing: 0) {
                TopStatusBar(
                    preset: model.selectedPreset,
                    frameRate: model.frameRate,
                    banner: model.banner ?? model.interruptionReason
                )
                Spacer(minLength: 0)
                ControlBar(model: model)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.shutterTrigger)
        .sensoryFeedback(.success, trigger: model.savedTrigger)
    }
}

// MARK: - Bottom control bar

private struct ControlBar: View {
    @Bindable var model: CameraViewModel

    var body: some View {
        VStack(spacing: 22) {
            PresetSelector(selection: $model.selectedPreset)

            HStack {
                CaptureStatusThumbnail(
                    image: model.lastThumbnail,
                    processingCount: model.processingCount,
                    action: model.openPhotosApp
                )
                Spacer()
                ShutterButton(isEnabled: model.canCapture, action: model.capture)
                Spacer()
                RawBadge(available: model.rawAvailable)
            }
            .padding(.horizontal, 36)
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Large circular shutter with press-scale feedback.
struct ShutterButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(.white).frame(width: 64, height: 64)
            }
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel("Take photo")
    }

    private struct ShutterPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .brightness(configuration.isPressed ? -0.15 : 0)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}

/// Compact capsule segmented control for looks. Selection updates the viewfinder on the next frame.
struct PresetSelector: View {
    @Binding var selection: ColorPreset
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ColorPreset.allCases) { preset in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = preset }
                } label: {
                    Text(preset.shortName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(selection == preset ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background {
                            if selection == preset {
                                Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: highlight)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.displayName)
                .accessibilityAddTraits(selection == preset ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Last developed photo + processing indicator. Tapping opens Photos.
struct CaptureStatusThumbnail: View {
    let image: UIImage?
    let processingCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.08))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .transition(.scale.combined(with: .opacity))
                        .id(image)
                }
                if processingCount > 0 {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.45))
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 52, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.25), value: image)
            .animation(.easeOut(duration: 0.2), value: processingCount)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(processingCount > 0 ? "Developing photo" : "Open Photos")
    }
}

private struct RawBadge: View {
    let available: Bool

    var body: some View {
        Text(available ? "RAW" : "NO RAW")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(available ? .white : .red)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            .frame(width: 52)
    }
}

// MARK: - Overlays

private struct TopStatusBar: View {
    let preset: ColorPreset
    let frameRate: Double
    let banner: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(preset.displayName.uppercased())
                if frameRate > 0 {
                    Text("·")
                    Text("\(Int(frameRate)) FPS")
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.35), in: Capsule())

            if let banner {
                Text(banner)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.75), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: banner)
    }
}

private struct ShutterBlink: View {
    let trigger: Int
    @State private var opacity: Double = 0

    var body: some View {
        Color.black
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                opacity = 0.85
                withAnimation(.easeOut(duration: 0.18)) { opacity = 0 }
            }
    }
}

private struct FocusIndicator: View {
    let trigger: Int
    @State private var scale: CGFloat = 1.4
    @State private var opacity: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear(perform: animate)
            .onChange(of: trigger) { _, _ in animate() }
    }

    private func animate() {
        scale = 1.4
        opacity = 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { scale = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(1.2)) { opacity = 0 }
    }
}

private struct PermissionView: View {
    let title: String
    let message: String
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
            if let action {
                Button("Open Settings", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
        }
        .padding(32)
    }
}

// MARK: - Xcode Previews

#Preview("Camera Controls") {
    @Previewable @State var preset: ColorPreset = .naturalFilm
    ZStack {
        LinearGradient(
            colors: [Color(white: 0.18), Color(white: 0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()

        VStack(spacing: 0) {
            TopStatusBar(preset: preset, frameRate: 60, banner: nil)
            Spacer()
            VStack(spacing: 22) {
                PresetSelector(selection: $preset)
                HStack {
                    CaptureStatusThumbnail(image: nil, processingCount: 0, action: {})
                    Spacer()
                    ShutterButton(isEnabled: true, action: {})
                    Spacer()
                    RawBadge(available: true)
                }
                .padding(.horizontal, 36)
            }
            .padding(.top, 20)
            .padding(.bottom, 8)
        }
    }
    .preferredColorScheme(.dark)
}

#Preview("Full Camera View") {
    CameraView()
}

