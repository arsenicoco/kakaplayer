import SwiftUI

/// Engine address entry. A later task adds discovered (Bonjour) engines above the manual
/// fields, so the manual form stays deliberately small.
struct SettingsView: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var port: String = ""
    @State private var testResult: TestResult = .none
    @State private var testing = false

    private enum TestResult: Equatable {
        case none
        case ok(String)
        case failed(String)
    }

    private var portNumber: Int { Int(port.trimmingCharacters(in: .whitespaces)) ?? MobileModel.defaultPort }
    private var canSave: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("The engine runs on your Mac (KakaPlayer) or another device on this network. In the iOS Simulator the Mac's own engine is reachable at 127.0.0.1.")
                        .font(MobileTheme.rounded(12))
                        .foregroundStyle(MobileTheme.textSecondary)

                    field(title: "Host", text: $host, placeholder: "192.168.1.10", keyboard: .URL)
                    field(title: "Port", text: $port, placeholder: "\(MobileModel.defaultPort)", keyboard: .numberPad)

                    Button { test() } label: {
                        HStack(spacing: 8) {
                            if testing {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text("Test connection").font(MobileTheme.rounded(14, .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .disabled(!canSave || testing)
                    .opacity(!canSave || testing ? 0.5 : 1)

                    switch testResult {
                    case .none:
                        EmptyView()
                    case .ok(let version):
                        resultLine("checkmark.circle.fill", "Engine answered · version \(version)", MobileTheme.ok)
                    case .failed(let message):
                        resultLine("exclamationmark.triangle.fill", message, MobileTheme.warn)
                    }
                }
                .padding(18)
            }
            .background(MobileTheme.bg.ignoresSafeArea())
            .navigationTitle("Engine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(MobileTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setEngine(host: host, port: portNumber)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? MobileTheme.accent : MobileTheme.textTertiary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            host = model.engineHost
            port = String(model.enginePort)
        }
    }

    private func field(title: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MobileTheme.rounded(12, .semibold))
                .foregroundStyle(MobileTheme.textTertiary)
            TextField("", text: text,
                      prompt: Text(placeholder).foregroundColor(MobileTheme.textTertiary))
                .font(MobileTheme.rounded(15).monospacedDigit())
                .foregroundStyle(MobileTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(MobileTheme.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MobileTheme.stroke, lineWidth: 1))
        }
    }

    private func resultLine(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(text).font(MobileTheme.rounded(12)).foregroundStyle(MobileTheme.textSecondary)
        }
    }

    /// Probes the address in the fields without committing it, so a typo can be corrected
    /// before it replaces a working setting.
    @MainActor
    private func test() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let literal = trimmed.contains(":") && !trimmed.hasPrefix("[") ? "[\(trimmed)]" : trimmed
        guard let url = URL(string: "http://\(literal):\(portNumber)") else {
            testResult = .failed("That host does not look like an address.")
            return
        }
        testing = true
        testResult = .none
        Task {
            let result = await MobileModel.probe(AceStreamAPI(baseURL: url, pid: MobileModel.clientPID))
            testing = false
            switch result {
            case .success(let version): testResult = .ok(version)
            case .failure(let error): testResult = .failed(error.localizedDescription)
            }
        }
    }
}
