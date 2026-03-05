import PhotosUI
import SwiftUI

/// Fullscreen remix editor — style, character, world prompts + mother keyframe + actions.
struct WorldSetupView: View {
    let gameId: String
    var apiClient: ForgeAPIClient?
    var auth: AuthManager?
    @Binding var config: WorldSetupConfig

    @Environment(\.dismiss) private var dismiss

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var keyframeImage: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isAnalyzing = false
    @State private var newActionName = ""

    var onRemixStarted: ((String) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    keyframeSection
                    nameSection
                    cameraSection
                    promptSection("STYLE", text: $config.style)
                    promptSection("CHARACTER", text: $config.character)
                    promptSection("WORLD", text: $config.world)
                    actionsSection
                    actionDescriptionsSection
                    baseMovementSection
                }
                .padding(16)
                .padding(.bottom, 80)
            }
            .background(ForgeTheme.background.ignoresSafeArea())
            .navigationTitle("WORLD SETUP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(ForgeTheme.dimWhite)
                }
            }
            .overlay(alignment: .bottom) { bottomBar }
        }
    }

    // MARK: - Keyframe

    private var keyframeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("MOTHER KEYFRAME")

            ZStack {
                if let img = keyframeImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 200)
                        .clipped()
                } else if let url = config.motherKeyframeUrl, !url.isEmpty {
                    AsyncImage(url: URL(string: url)) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            placeholder
                        }
                    }
                    .frame(height: 200)
                    .clipped()
                } else {
                    placeholder
                        .frame(height: 200)
                }
            }
            .border(ForgeTheme.border, width: ForgeTheme.borderWidth)

            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Replace", systemImage: "photo")
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(ForgeTheme.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .border(ForgeTheme.cyan.opacity(0.5), width: 1)
                }

                if keyframeImage != nil {
                    Button {
                        analyzeKeyframe()
                    } label: {
                        Group {
                            if isAnalyzing {
                                ProgressView().tint(ForgeTheme.orange)
                            } else {
                                Label("Analyze", systemImage: "sparkles")
                            }
                        }
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(ForgeTheme.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .border(ForgeTheme.orange.opacity(0.5), width: 1)
                    }
                    .disabled(isAnalyzing)
                }
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            loadPhoto(item)
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(ForgeTheme.surface)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title2)
                    Text("Tap Replace to set keyframe")
                        .font(ForgeTheme.captionFont)
                }
                .foregroundStyle(ForgeTheme.dimWhite)
            }
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("GAME NAME")
            TextField("Game name", text: $config.gameName)
                .font(ForgeTheme.bodyFont)
                .padding(ForgeTheme.buttonPadding)
                .background(ForgeTheme.surface)
                .border(ForgeTheme.border, width: ForgeTheme.borderWidth)
                .foregroundStyle(ForgeTheme.white)
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("CAMERA TYPE")
            Picker("Camera", selection: $config.cameraType) {
                Text("Side Scroll").tag("side_scroll")
                Text("Top Down").tag("top_down")
                Text("First Person").tag("first_person")
                Text("Third Person").tag("third_person")
            }
            .pickerStyle(.segmented)
            .tint(ForgeTheme.cyan)
        }
    }

    // MARK: - Prompts

    private func promptSection(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title)
            TextEditor(text: text)
                .font(ForgeTheme.bodyFont)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80)
                .padding(8)
                .background(ForgeTheme.surface)
                .border(ForgeTheme.border, width: ForgeTheme.borderWidth)
                .foregroundStyle(ForgeTheme.white)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ACTIONS")

            ForEach(Array(config.actions.enumerated()), id: \.element.id) { index, action in
                HStack {
                    Text(action.name)
                        .font(ForgeTheme.bodyFont)
                        .foregroundStyle(ForgeTheme.white)
                    Spacer()
                    Button {
                        config.actions.remove(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(ForgeTheme.captionFont)
                            .foregroundStyle(ForgeTheme.red)
                    }
                }
                .padding(8)
                .background(ForgeTheme.surface)
                .border(ForgeTheme.border, width: 1)
            }

            HStack {
                TextField("New action", text: $newActionName)
                    .font(ForgeTheme.bodyFont)
                    .padding(8)
                    .background(ForgeTheme.surface)
                    .border(ForgeTheme.border, width: 1)
                    .foregroundStyle(ForgeTheme.white)

                Button {
                    let trimmed = newActionName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        config.actions.append(GameAction(name: trimmed))
                        newActionName = ""
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(ForgeTheme.bodyFont)
                        .foregroundStyle(ForgeTheme.cyan)
                        .padding(8)
                        .border(ForgeTheme.cyan.opacity(0.5), width: 1)
                }
            }
        }
    }

    // MARK: - Action Descriptions

    private var actionDescriptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ACTION DESCRIPTIONS")
            Text("Describe what each action looks like as an animation")
                .font(ForgeTheme.captionFont)
                .foregroundStyle(ForgeTheme.dimWhite)

            let nonNoopActions = config.actions.filter { $0.name.lowercased() != "noop" }
            ForEach(nonNoopActions, id: \.id) { action in
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.name.uppercased())
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(ForgeTheme.cyan)

                    TextEditor(text: Binding(
                        get: { config.actionDescriptions[action.name] ?? "" },
                        set: { config.actionDescriptions[action.name] = $0.isEmpty ? nil : $0 }
                    ))
                    .font(ForgeTheme.bodyFont)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 50)
                    .padding(8)
                    .background(ForgeTheme.surface)
                    .border(ForgeTheme.border, width: ForgeTheme.borderWidth)
                    .foregroundStyle(ForgeTheme.white)
                }
            }
        }
    }

    // MARK: - Base Movement

    private var baseMovementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("BASE MOVEMENT")
            Text("Describe the idle/cruise animation (e.g. \"cruising forward through the level\")")
                .font(ForgeTheme.captionFont)
                .foregroundStyle(ForgeTheme.dimWhite)

            TextEditor(text: $config.baseMovement)
                .font(ForgeTheme.bodyFont)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 50)
                .padding(8)
                .background(ForgeTheme.surface)
                .border(ForgeTheme.border, width: ForgeTheme.borderWidth)
                .foregroundStyle(ForgeTheme.white)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let error = errorMessage {
                Text(error)
                    .font(ForgeTheme.captionFont)
                    .foregroundStyle(ForgeTheme.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            Button {
                remixAndBuild()
            } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(ForgeTheme.background)
                    } else {
                        Text("REMIX & BUILD")
                            .font(ForgeTheme.bodyFont)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(ForgeTheme.buttonPadding)
                .background(ForgeTheme.cyan)
                .foregroundStyle(ForgeTheme.background)
            }
            .disabled(isSaving)
            .padding(16)
        }
        .background(ForgeTheme.background)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(ForgeTheme.captionFont)
            .foregroundStyle(ForgeTheme.orange)
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                keyframeImage = image
            }
        }
    }

    private func analyzeKeyframe() {
        guard let client = apiClient,
              let image = keyframeImage,
              let data = image.jpegData(compressionQuality: 0.8) else { return }
        isAnalyzing = true
        Task {
            do {
                let analysis = try await client.analyzeKeyframe(imageData: data)
                if let s = analysis.style { config.style = s }
                if let c = analysis.character { config.character = c }
                if let w = analysis.world { config.world = w }
            } catch {
                errorMessage = "Analysis failed: \(error.localizedDescription)"
            }
            isAnalyzing = false
        }
    }

    private func remixAndBuild() {
        guard let client = apiClient else {
            errorMessage = "Not connected"
            return
        }
        isSaving = true
        errorMessage = nil
        print("[WorldSetup] remixAndBuild called, gameId=\(gameId)")
        Task {
            do {
                // Upload keyframe if replaced
                if let image = keyframeImage,
                   let jpegData = image.jpegData(compressionQuality: 0.85) {
                    print("[WorldSetup] Uploading keyframe...")
                    let asset = try await client.uploadKeyframe(imageData: jpegData)
                    config.motherKeyframeId = asset.id
                    print("[WorldSetup] Keyframe uploaded: \(asset.id)")
                }

                // Start server-side remix pipeline (adapt prompts → generate clips → save → build)
                print("[WorldSetup] Starting remix for gameId=\(gameId)...")
                let response = try await client.startRemix(gameId: gameId, config: config)
                print("[WorldSetup] Remix started: \(response.remixId)")

                onRemixStarted?(gameId)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                print("[WorldSetup] Remix failed: \(error)")
            }
            isSaving = false
        }
    }
}
