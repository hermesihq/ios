import SwiftUI

/// One screen: the settings, and the three things an app does with the SDK.
struct ContentView: View {
    @ObservedObject var model: Model
    @State private var apiBaseURL = Settings().apiBaseURL
    @State private var publicKey = Settings().publicKey
    @State private var tokenServerURL = Settings().tokenServerURL
    @State private var subscriber = Settings().subscriber

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Settings"), footer: Text("Start the token server first (see the README).")) {
                    field("Hermesi client API", text: $apiBaseURL)
                    field("Public key (hm_pk_...)", text: $publicKey)
                    field("Token server", text: $tokenServerURL)
                    field("Subscriber (external id)", text: $subscriber)
                    Button("Save settings") {
                        model.save(apiBaseURL: apiBaseURL, publicKey: publicKey, tokenServerURL: tokenServerURL, subscriber: subscriber)
                    }
                }
                Section(header: Text("Steps")) {
                    Button("1. Allow notifications") { model.requestPermission() }
                    Button("2. Register this device") { model.register() }
                    Button("3. Unregister this device") { model.unregister() }
                }
                Section(header: Text("Log")) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote)
                    }
                }
            }
            .navigationTitle("Hermesi Push")
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
        }
    }
}
