import SwiftUI

#if os(iOS)
  struct ImportWalletView: View {
    @ObservedObject var vm: WalletViewModel
    var onSuccess: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var groupName = ""
    @FocusState private var isInputFocused: Bool

    private var isValid: Bool {
      let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
      let hex = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
      let words = trimmed.split(whereSeparator: \.isWhitespace)
      let hasName = !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return hasName
        && ((hex.count == 64 && hex.allSatisfy(\.isHexDigit))
          || [12, 15, 18, 21, 24].contains(words.count))
    }

    var body: some View {
      VStack(spacing: 32) {
        Spacer()
        VStack(spacing: 24) {
          Text("import wallet")
            .font(.largeTitle)
            .fontWeight(.bold)
          TextField("wallet name", text: $groupName)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
          TextField("enter private key or seed phrase", text: $inputText, axis: .vertical)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.center)
            .lineLimit(5...10)
            .frame(height: 120)
            .padding(12)
            .background(Color.secondary.opacity(0.2))
            .cornerRadius(12)
            .focused($isInputFocused)

          Button {
            Task {
              if await vm.importWallet(input: inputText, groupName: groupName) {
                inputText = ""
                groupName = ""
                onSuccess()
                dismiss()
              }
            }
          } label: {
            HStack {
              if vm.isSaving {
                ProgressView().tint(.white)
              } else {
                Text("Save").font(.headline)
              }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
          }
          .buttonStyle(.borderedProminent)
          .disabled(!isValid || vm.isSaving)

          if let error = vm.errorMessage, !error.isEmpty {
            Text(error)
              .foregroundStyle(.red)
              .font(.footnote)
              .multilineTextAlignment(.center)
          }
        }
        .padding(.horizontal, 32)
        Spacer()
        Spacer()
      }
      .navigationBarTitleDisplayMode(.inline)
      .contentShape(Rectangle())
      .onAppear { vm.errorMessage = nil }
      .onTapGesture { isInputFocused = false }
    }
  }
#endif
