#if os(iOS)
import LumaRemoteCore
import SwiftUI
import UIKit

/// The keyboard bridge: a field whose committed text is mirrored into the TV's, as backspaces back to
/// where it differs and then the new text. Return sends enter and starts afresh; a backspace in the empty
/// field still deletes on the TV.
struct KeyboardPanel: View {
    let onClose: () -> Void

    @Environment(RemoteModel.self) private var model
    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        HStack(spacing: KeyMetrics.gap) {
            BridgeField(model: model, ime: model.state.ime, typeface: theme.typefaces.regular, ink: UIColor(theme.palette.ink), tint: UIColor(theme.palette.accent))
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: theme.radii.control, style: .continuous).fill(theme.palette.surfaceRaised))
            GlyphButton(symbol: "keyboard.chevron.compact.down", label: "Hide keyboard", action: onClose)
        }
        .padding(KeyMetrics.gap)
        .background(theme.palette.surface)
        .overlay(alignment: .top) { theme.palette.edge.frame(height: 0.5) }
    }
}

private struct BridgeField: UIViewRepresentable {
    let model: RemoteModel
    let ime: IMEState
    let typeface: String?
    let ink: UIColor
    let tint: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> BackspaceField {
        let field = BackspaceField()
        let coordinator = context.coordinator
        field.delegate = coordinator
        field.addTarget(coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.onEmptyBackspace = { coordinator.model.edit(.backspace(1)) }
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.adjustsFontForContentSizeCategory = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.accessibilityLabel = "Text for the TV"
        field.accessibilityIdentifier = "remote.keyboard.field"
        Task { @MainActor in field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: BackspaceField, context: Context) {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let font = typeface.flatMap { UIFont(name: $0, size: 17) }.map { UIFontMetrics(forTextStyle: .body).scaledFont(for: $0) } ?? body
        if field.font != font { field.font = font }
        field.textColor = ink
        field.tintColor = tint
        context.coordinator.configure(field, for: ime)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        let model: RemoteModel
        /// The field's text as the TV last heard it.
        private var sent = ""
        private var configured: IMEState?

        init(model: RemoteModel) {
            self.model = model
        }

        @objc func changed(_ field: UITextField) {
            // Text still being composed, such as a Japanese reading, goes over once it is chosen.
            guard field.markedTextRange == nil else { return }
            let text = field.text ?? ""
            model.type(from: sent, to: text)
            sent = text
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            guard field.markedTextRange == nil else { return true }
            model.edit(.enter)
            field.text = ""
            sent = ""
            return false
        }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard let limit = configured?.max, limit > 0, let text = field.text, let range = Range(range, in: text) else { return true }
            return text.replacingCharacters(in: range, with: string).count <= limit
        }

        /// Keyboard type, Return key, capitals, corrections and secure entry, from the TV field's kind.
        func configure(_ field: UITextField, for ime: IMEState) {
            guard configured != ime else { return }
            configured = ime
            let purpose = ime.purposeKind
            field.keyboardType = switch purpose {
            case .digits, .number: .numbersAndPunctuation
            case .phone: .phonePad
            case .url: .URL
            case .email: .emailAddress
            default: .default
            }
            field.returnKeyType = switch ime.enterKind {
            case .done: .done
            case .go: .go
            case .send: .send
            case .search: .search
            case .next: .next
            default: .default
            }
            let literal = ime.sensitive || ime.hiddenText || [.url, .email, .password, .terminal].contains(purpose)
            field.autocapitalizationType = if ime.uppercase {
                .allCharacters
            } else if ime.titlecase || purpose == .name {
                .words
            } else if ime.lowercase || literal {
                .none
            } else {
                .sentences
            }
            field.autocorrectionType = literal ? .no : .default
            field.spellCheckingType = literal ? .no : .default
            field.isSecureTextEntry = ime.hiddenText
            field.textContentType = switch purpose {
            case .password: .password
            case .email: .emailAddress
            case .url: .URL
            default: nil
            }
            if field.isFirstResponder { field.reloadInputViews() }
        }
    }
}

final class BackspaceField: UITextField {
    var onEmptyBackspace: (() -> Void)?

    override func deleteBackward() {
        if (text ?? "").isEmpty { onEmptyBackspace?() }
        super.deleteBackward()
    }
}
#endif
