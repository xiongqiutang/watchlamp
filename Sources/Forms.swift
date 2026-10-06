import AppKit

/// "Rate Watchlamp…" and "Send a Suggestion…": small windows that send to reviews.thermport.com.
/// Reviews show on Watchlamp's page once the developer approves them; suggestions only reach the developer.
/// Watchlamp's source is public, so there is no key to send along: the server limits each Mac (a random ID
/// made here) and each address per day, and a person checks everything before it is shown.
@MainActor
final class FormWindow: NSObject, NSWindowDelegate {
    enum Kind { case review, suggestion }

    private static var shown: [Kind: FormWindow] = [:]
    private let kind: Kind
    private let window: NSWindow
    private let text = NSTextView()
    private let name = NSTextField()
    private let contact = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let send = NSButton()
    private var stars: [NSButton] = []
    private var rating = 0

    static func show(_ kind: Kind) {
        let form = shown[kind] ?? FormWindow(kind)
        shown[kind] = form
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        form.window.makeKeyAndOrderFront(nil)
        form.window.makeFirstResponder(form.text)
    }

    private init(_ kind: Kind) {
        self.kind = kind
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = L(kind == .review ? "Rate Watchlamp" : "Send a Suggestion")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self

        let intro = NSTextField(wrappingLabelWithString: L(kind == .review
            ? "Reviews appear on Watchlamp's page at thermport.com after a quick check."
            : "Something missing, or not working right? Tell us. We read every message."))
        intro.textColor = .secondaryLabelColor
        var rows: [NSView] = [intro]
        if kind == .review {
            let row = NSStackView()
            row.spacing = 2
            for n in 1...5 {
                let star = NSButton(title: "", target: self, action: #selector(rate(_:)))
                star.tag = n
                star.isBordered = false
                star.imagePosition = .imageOnly
                star.setAccessibilityLabel("\(n)")
                star.widthAnchor.constraint(equalToConstant: 30).isActive = true
                star.heightAnchor.constraint(equalToConstant: 28).isActive = true
                stars.append(star)
                row.addArrangedSubview(star)
            }
            paint()
            rows += [caption(L("Your rating")), row]
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.heightAnchor.constraint(equalToConstant: kind == .review ? 96 : 120).isActive = true
        rows += [caption(L(kind == .review ? "Your review" : "Your suggestion")), scroll]
        name.placeholderString = L("Name (optional)")
        rows.append(name)
        if kind == .suggestion {
            contact.placeholderString = L("Email (optional, if you'd like a reply)")
            rows.append(contact)
        }
        status.textColor = .secondaryLabelColor
        rows.append(status)

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(dismiss))
        cancel.keyEquivalent = "\u{1b}"
        send.title = L("Send")
        send.bezelStyle = .rounded
        send.target = self
        send.action = #selector(submit)
        send.keyEquivalent = "\r"   // from the name or email field; in the text, Return starts a new line
        let buttons = NSStackView(views: [NSView(), cancel, send])
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.setCustomSpacing(14, after: intro)
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        for view in rows {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        intro.preferredMaxLayoutWidth = 400
        status.preferredMaxLayoutWidth = 400
        stack.userInterfaceLayoutDirection = Lang.rtl ? .rightToLeft : .leftToRight
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
    }

    private func caption(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        return label
    }

    private func paint() {
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        for star in stars {
            let filled = star.tag <= rating
            star.image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            star.contentTintColor = filled ? .systemYellow : .tertiaryLabelColor
        }
    }

    @objc private func rate(_ sender: NSButton) {
        rating = sender.tag
        paint()
    }

    @objc private func dismiss() { window.close() }

    func windowWillClose(_ notification: Notification) {
        Self.shown[kind] = nil
    }

    private func say(_ message: String, error: Bool) {
        status.stringValue = message
        status.textColor = error ? .systemRed : .secondaryLabelColor
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
    }

    @objc private func submit() {
        let words = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .review && rating == 0 { return say(L("Please pick a star rating."), error: true) }
        if words.isEmpty { return say(L("Please write a few words."), error: true) }
        var body: [String: Any] = ["product": "watchlamp", "text": words, "version": Updates.current, "lang": Lang.active,
                                   "name": name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)]
        if kind == .review { body["stars"] = rating }
        if kind == .suggestion { body["contact"] = contact.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        let api = ProcessInfo.processInfo.environment["WATCHLAMP_API"] ?? "https://reviews.thermport.com"   // for testing
        var request = URLRequest(url: URL(string: api + (kind == .review ? "/review" : "/feedback"))!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.device, forHTTPHeaderField: "X-Watchlamp-Device")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        send.isEnabled = false
        say(L("Sending…"), error: false)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in self.finish(code) }
        }.resume()
    }

    private func finish(_ code: Int) {
        switch code {
        case 201:
            say(L(kind == .review ? "Thank you! Your review will appear after a quick check." : "Thanks! We got your suggestion."),
                error: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.window.close() }
        case 429:
            say(L("You've already sent one today. Please try again tomorrow."), error: true)
            send.isEnabled = true
        default:
            say(L("Couldn't send. Check your internet connection and try again."), error: true)
            send.isEnabled = true
        }
    }

    /// A random ID for this Mac, used only by the server to limit how often it accepts reviews and suggestions.
    private static var device: String {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }
}

#if DEVTOOLS
extension FormWindow {
    /// `form review|suggestion <lang> --send`: fills the window in and sends it (point WATCHLAMP_API at a test server),
    /// then prints what the window says.
    static func sendTest(_ kind: Kind) {
        guard let form = shown[kind] else { return }
        form.rating = 4
        form.paint()
        form.text.string = "Test from the Watchlamp app"
        form.name.stringValue = "Tester"
        form.contact.stringValue = "tester@example.com"
        form.submit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print(form.status.stringValue)
            exit(0)
        }
    }
}
#endif
