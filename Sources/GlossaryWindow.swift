import AppKit
import UniformTypeIdentifiers

final class GlossaryWindow: NSObject, NSSearchFieldDelegate {
    var onChange: (() -> Void)?

    private let store: GlossaryStore
    private var window: NSWindow!
    private var root: ThemeRootView!
    private var searchField: NSSearchField!
    private var categoryPicker: NSPopUpButton!
    private var countLabel: NSTextField!
    private var listView: NSTextView!
    private var scroll: NSScrollView!
    private var addButton: NSButton!

    init(store: GlossaryStore) {
        self.store = store
        super.init()
        makeWindow()
    }

    func show() {
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "课译 · 术语表"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        window.center()
        root = ThemeRootView()
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in
            guard let self else { return }
            self.applyTheme(AppPalette(appearance: self.root.effectiveAppearance,
                                       accent: AccentChoice.saved))
        }
        window.contentView = root

        searchField = NSSearchField()
        searchField.placeholderString = "搜索英文、中文或解释"
        searchField.delegate = self
        categoryPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        categoryPicker.addItems(withTitles: ["全部术语", "软件开发", "软件工程", "数据库",
                                             "系统与网络", "原课程与自定义"])
        categoryPicker.target = self
        categoryPicker.action = #selector(categoryChanged)
        countLabel = NSTextField(labelWithString: "")
        countLabel.textColor = .secondaryLabelColor

        scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        listView = NSTextView(frame: NSRect(x: 0, y: 0, width: 650, height: 400))
        listView.isEditable = false
        listView.isSelectable = true
        listView.drawsBackground = false
        listView.font = NSFont.systemFont(ofSize: 14)
        listView.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = listView

        addButton = NSButton(title: "添加术语", target: self, action: #selector(addTerm))
        let importButton = NSButton(title: "导入 TSV", target: self, action: #selector(importTerms))
        for view in [searchField!, categoryPicker!, countLabel!, scroll!, addButton!, importButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: categoryPicker.leadingAnchor, constant: -10),
            categoryPicker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            categoryPicker.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            categoryPicker.widthAnchor.constraint(equalToConstant: 140),
            countLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            countLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -14),
            addButton.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            importButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 10),
            importButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor)
        ])
        applyTheme(AppPalette(appearance: root.effectiveAppearance, accent: AccentChoice.saved))
    }

    func applyTheme(_ palette: AppPalette) {
        window?.backgroundColor = palette.background
        root?.layer?.backgroundColor = palette.background.cgColor
        countLabel?.textColor = palette.secondary
        scroll?.layer?.backgroundColor = palette.surface.cgColor
        scroll?.layer?.borderColor = palette.border.cgColor
        scroll?.layer?.borderWidth = 1
        scroll?.layer?.cornerRadius = 12
        listView?.textColor = palette.text
        addButton?.bezelColor = palette.accent
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    @objc private func categoryChanged() { refresh() }

    private func refresh() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = categoryPicker.titleOfSelectedItem ?? "全部术语"
        let addedCategories: Set<String> = ["软件开发", "软件工程", "数据库", "系统与网络"]
        let matching = store.terms.filter {
            let inCategory = category == "全部术语" || $0.course == category ||
                (category == "原课程与自定义" && !addedCategories.contains($0.course))
            return inCategory && (query.isEmpty ||
                $0.english.localizedCaseInsensitiveContains(query) ||
                $0.chinese.localizedCaseInsensitiveContains(query) ||
                $0.explanation.localizedCaseInsensitiveContains(query))
        }
        countLabel.stringValue = "\(matching.count) 条术语 · 新增或导入的词在下次开始收声时参与识别增强"
        listView.string = matching.map { term in
            let explanation = term.explanation.isEmpty ? "" : "\n  \(term.explanation)"
            return "\(term.english)  →  \(term.chinese)\(explanation)\n  \(term.course) · \(term.source ?? "无来源")"
        }.joined(separator: "\n\n")
    }

    @objc private func addTerm() {
        let alert = NSAlert()
        alert.messageText = "添加术语"
        alert.informativeText = "填写英文术语和中文释义。"
        let fields = NSStackView()
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 330, height: 60)
        let english = NSTextField()
        english.placeholderString = "英文术语"
        let chinese = NSTextField()
        chinese.placeholderString = "中文释义"
        fields.addArrangedSubview(english)
        fields.addArrangedSubview(chinese)
        alert.accessoryView = fields
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.add(english: english.stringValue, chinese: chinese.stringValue)
            refresh()
            onChange?()
        } catch { showError(error) }
    }

    @objc private func importTerms() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try store.importTSV(url)
            refresh()
            onChange?()
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "术语表操作失败"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
