import SwiftUI

/// Holds the OpenRouter API key and picks which of its models explains passages.
struct AISettingsView: View {
    @Environment(LLMSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-or-…", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("OpenRouter API Key")
                } footer: {
                    Text("One key covers every model. Create one at openrouter.ai/keys. It stays in this device's Keychain.")
                }

                Section("Model") {
                    Picker("Model", selection: $settings.model) {
                        ForEach(PresetModel.allCases) { Text($0.displayName).tag($0.slug) }
                        if !PresetModel.allCases.contains(where: { $0.slug == settings.model }) {
                            Text(settings.model).tag(settings.model)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    NavigationLink("Browse All Models…") { ModelCatalogView() }
                }
            }
            .navigationTitle("Explanations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { apiKey = settings.apiKey }
            .onChange(of: apiKey) { settings.apiKey = apiKey }
        }
    }
}

/// Searchable list of everything OpenRouter serves.
private struct ModelCatalogView: View {
    @Environment(LLMSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var models: [CatalogModel] = []
    @State private var query = ""
    @State private var failure: String?

    private var matches: [CatalogModel] {
        let words = query.lowercased().split(separator: " ")
        return models.filter { model in
            let text = (model.name + " " + model.id).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        List(matches) { model in
            Button {
                settings.model = model.id
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.name)
                        Text(model.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.id == settings.model { Image(systemName: "checkmark") }
                }
            }
            .foregroundStyle(.primary)
        }
        .overlay {
            if models.isEmpty {
                if let failure {
                    ContentUnavailableView("Couldn't Load Models", systemImage: "wifi.slash", description: Text(failure))
                } else {
                    ProgressView()
                }
            }
        }
        .searchable(text: $query, prompt: "Search models")
        .navigationTitle("All Models")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { models = try await OpenRouter.catalog() } catch { failure = error.localizedDescription }
        }
    }
}
