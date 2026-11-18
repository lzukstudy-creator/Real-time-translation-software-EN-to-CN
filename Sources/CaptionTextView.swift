import AppKit
import Translation

/// Follows new captions until the reader scrolls away from the bottom.
final class CaptionTextView: NSTextView {
    private var definition: NSPopover?
    private var lookup: Task<Void, Never>?
    private static let words = try! NSRegularExpression(pattern: "[A-Za-z]+(?:[’'-][A-Za-z]+)*")

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0,
              let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return }
        let index = layout.characterIndexForGlyph(at: glyph)
        let source = string as NSString
        let line = source.lineRange(for: NSRange(location: index, length: 0))
        guard let match = Self.words.matches(in: string, range: line).first(where: { NSLocationInRange(index, $0.range) }) else { return }
        let word = source.substring(with: match.range)
        let glyphs = layout.glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
        let anchor = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
        lookup?.cancel()
        definition?.close()
        let label = NSTextField(wrappingLabelWithString: word + " · 查询中…")
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 66))
        label.frame = controller.view.bounds.insetBy(dx: 12, dy: 8)
        controller.view.addSubview(label)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        definition = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        lookup = Task { @MainActor in
            let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
            let meaning = try? await session.translate(word).targetText
            guard !Task.isCancelled else { return }
            label.stringValue = word + "\n" + (meaning ?? "暂时无法查询中文释义")
        }
    }

    /// 悬浮字幕：固定行高、快速淡入。
    var smoothFloatingCaptions = false
    /// 常规字幕（主窗口、沉浸字幕）：新出现的英中文字淡入，并平滑上移到最新位置。
    var animatesCaptions = false
    private(set) var captionStyle = CaptionStyle.saved
    private struct CaptionFade {
        var range: NSRange
        let start: TimeInterval
    }
    private var fades: [CaptionFade] = []
    private var fadeTimer: Timer?
    private var followTimer: Timer?
    private var followTarget: CGFloat?
    private var scrollObserver: NSObjectProtocol?
    private var followsBottom = true
    private var updating = false
    private var displayedFontSize: CGFloat = 0
    private var primaryTextColor: NSColor = .labelColor
    private var secondaryTextColor: NSColor = .secondaryLabelColor
    /// 重点标记的颜色（跟随点缀色）。
    var markColor: NSColor = .systemOrange {
        didSet { if markColor != oldValue { applyLineStyles() } }
    }

    private var animationEnabled: Bool { smoothFloatingCaptions || animatesCaptions }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// 一次变化超过这个长度（切换回看、切换语言等整体替换）时不做淡入，避免整屏闪动。
    private static let maximumFadeLength = 800

    deinit {
        fadeTimer?.invalidate()
        followTimer?.invalidate()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func observeScrolling() {
        guard scrollObserver == nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            guard let self, !self.updating else { return }
            self.cancelSmoothFollow()
            self.followsBottom = self.distanceToBottom(in: clip) <= 24
        }
    }

    func updateCaptions(_ content: String, fontSize: CGFloat, allowFollow: Bool = true, resetFollow: Bool = false) {
        observeScrolling()
        let changed = string != content
        guard changed || displayedFontSize != fontSize || resetFollow else { return }
        let clip = enclosingScrollView?.contentView
        let oldOrigin = clip?.bounds.origin
        let shouldFollow = allowFollow && followsBottom
        updating = true
        if displayedFontSize != fontSize { clearCaptionFades() }
        var changedRange: NSRange?
        let newFont = captionStyle.font.font(ofSize: fontSize, weight: .regular)
        if changed, let storage = textStorage {
            let oldUnits = Array(storage.string.utf16)
            let newUnits = Array(content.utf16)
            var prefix = 0
            while prefix < min(oldUnits.count, newUnits.count),
                  oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(oldUnits.count, newUnits.count) - prefix,
                  oldUnits[oldUnits.count - suffix - 1] == newUnits[newUnits.count - suffix - 1] {
                suffix += 1
            }
            let replacementRange = NSRange(location: prefix,
                                           length: oldUnits.count - prefix - suffix)
            let newRange = NSRange(location: prefix,
                                   length: newUnits.count - prefix - suffix)
            let replacement = (content as NSString).substring(with: newRange)
            if newRange.length > 0 {
                changedRange = (content as NSString).rangeOfComposedCharacterSequences(for: newRange)
            }
            // 只结束与本次修改重叠或位于其后的淡入；更早的字幕继续完成自己的淡入，不会闪一下。
            keepCaptionFades(endingBefore: changedRange?.location ?? prefix)
            storage.beginEditing()
            storage.replaceCharacters(in: replacementRange,
                                      with: NSAttributedString(string: replacement,
                                                               attributes: [.font: newFont]))
            storage.endEditing()
        } else if changed {
            clearCaptionFades()
            string = content
        }
        if displayedFontSize != fontSize {
            font = newFont
        }
        displayedFontSize = fontSize
        applyLineStyles()
        if resetFollow {
            resumeFollowing()
        } else if shouldFollow, animationEnabled, let clip, let oldOrigin {
            if let layoutManager, let textContainer {
                layoutManager.ensureLayout(for: textContainer)
            }
            clip.scroll(to: oldOrigin)
            enclosingScrollView?.reflectScrolledClipView(clip)
            smoothFollow(in: clip)
        } else if shouldFollow {
            scrollToEndOfDocument(nil)
        } else if let clip, let oldOrigin {
            cancelSmoothFollow()
            clip.scroll(to: oldOrigin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        updating = false
        if let changedRange { fadeInCaptionText(in: changedRange) }
    }

    private func keepCaptionFades(endingBefore location: Int) {
        guard !fades.isEmpty else { return }
        let length = textStorage?.length ?? 0
        fades.removeAll { fade in
            guard NSMaxRange(fade.range) > location else { return false }
            if NSMaxRange(fade.range) <= length {
                layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fade.range)
            }
            return true
        }
        if fades.isEmpty { stopFadeTimer() }
    }

    private func clearCaptionFades() {
        let length = textStorage?.length ?? 0
        for fade in fades where NSMaxRange(fade.range) <= length {
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fade.range)
        }
        fades.removeAll()
        stopFadeTimer()
    }

    private func stopFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    /// 淡入参数：悬浮字幕保持原来的快速轻淡入；常规字幕淡入更完整。
    /// 开启“减少动态效果”时只保留短暂的透明度过渡，不做滚动动画（符合 macOS 的建议）。
    private var fadeDuration: TimeInterval {
        if reduceMotion { return smoothFloatingCaptions ? 0 : 0.18 }
        return smoothFloatingCaptions ? 0.16 : 0.34
    }
    private var fadeStartOpacity: CGFloat { smoothFloatingCaptions ? 0.55 : 0.12 }

    private func fadeInCaptionText(in range: NSRange) {
        guard animationEnabled, fadeDuration > 0, window?.isVisible == true,
              range.length > 0, range.length <= Self.maximumFadeLength,
              let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        fades.append(CaptionFade(range: range, start: ProcessInfo.processInfo.systemUptime))
        if fades.count > 40 {
            let finished = fades.removeFirst()
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: finished.range)
        }
        stepCaptionFades()
        guard fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.stepCaptionFades()
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepCaptionFades() {
        guard let storage = textStorage, let layout = layoutManager else {
            clearCaptionFades()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let duration = max(fadeDuration, 0.01)
        let startOpacity = fadeStartOpacity
        fades.removeAll { fade in
            guard NSMaxRange(fade.range) <= storage.length else { return true }
            let progress = (now - fade.start) / duration
            guard progress < 1 else {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fade.range)
                return true
            }
            // easeOutCubic：开始快、结尾柔和。
            let eased = 1 - pow(1 - max(0, progress), 3)
            let opacity = startOpacity + (1 - startOpacity) * CGFloat(eased)
            storage.enumerateAttribute(.foregroundColor, in: fade.range) { value, run, _ in
                guard let color = value as? NSColor else { return }
                layout.addTemporaryAttribute(.foregroundColor,
                                             value: color.withAlphaComponent(color.alphaComponent * opacity),
                                             forCharacterRange: run)
            }
            return false
        }
        if fades.isEmpty { stopFadeTimer() }
    }

    private func cancelSmoothFollow() {
        followTimer?.invalidate()
        followTimer = nil
        followTarget = nil
    }

    private func smoothFollow(in clip: NSClipView) {
        let target = clip.bounds.minY + max(0, distanceToBottom(in: clip))
        guard abs(target - clip.bounds.minY) > 0.5, !reduceMotion else {
            cancelSmoothFollow()
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
            enclosingScrollView?.reflectScrolledClipView(clip)
            return
        }
        followTarget = target
        guard followTimer == nil else { return }
        // 常规字幕移动距离通常更大，使用稍慢的跟随系数，让新行平滑上移。
        let factor: CGFloat = smoothFloatingCaptions ? 0.24 : 0.18
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak clip] timer in
            guard let self, let clip, let target = self.followTarget else {
                timer.invalidate()
                return
            }
            let remaining = target - clip.bounds.minY
            let finished = abs(remaining) <= 1
            self.updating = true
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: finished ? target : clip.bounds.minY + remaining * factor))
            self.enclosingScrollView?.reflectScrolledClipView(clip)
            self.updating = false
            if finished { self.cancelSmoothFollow() }
        }
        followTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 应用用户选择的字幕字体与颜色。
    func applyStyle(_ style: CaptionStyle, palette: AppPalette) {
        captionStyle = style
        let colors = style.color.colors(palette: palette)
        updateTheme(primary: colors.chinese, secondary: colors.english)
    }

    func updateTheme(primary: NSColor, secondary: NSColor) {
        clearCaptionFades()
        cancelSmoothFollow()
        primaryTextColor = primary
        secondaryTextColor = secondary
        let clip = enclosingScrollView?.contentView
        let oldOrigin = clip?.bounds.origin
        updating = true
        applyLineStyles()
        if followsBottom {
            scrollToEndOfDocument(nil)
        } else if let clip, let oldOrigin {
            clip.scroll(to: oldOrigin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        updating = false
    }

    private func applyLineStyles() {
        guard let storage = textStorage else { return }
        let source = storage.string as NSString
        let baseSize = max(14, displayedFontSize > 0 ? displayedFontSize : (font?.pointSize ?? 19))
        let fontChoice = captionStyle.font
        let chineseFont = fontChoice.font(ofSize: baseSize + 1, weight: .medium)
        let englishFont = fontChoice.font(ofSize: baseSize - 1, weight: .regular)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: source.length))
        var markedBlock = false
        if smoothFloatingCaptions, source.length > 0 {
            let paragraph = NSMutableParagraphStyle()
            let height = ceil(baseSize * 1.5)
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            storage.addAttribute(.paragraphStyle, value: paragraph,
                                 range: NSRange(location: 0, length: source.length))
        }
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) {
            [self] line, range, _, _ in
            guard let line, !line.isEmpty, range.length > 0 else { markedBlock = false; return }
            let hasChinese = line.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
            let stampLength = Self.stampLength(line)
            let starred = (line as NSString).substring(from: stampLength).hasPrefix(CaptionTimeline.markSymbol)
            if starred { markedBlock = true } else if !hasChinese { markedBlock = false }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = hasChinese ? 8 : 2
            storage.addAttributes([
                .font: hasChinese ? chineseFont : englishFont,
                .foregroundColor: hasChinese ? primaryTextColor : secondaryTextColor
            ], range: range)
            if !smoothFloatingCaptions {
                storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
            // 重点：英文和对应中文加淡色底，像荧光笔划过；星号用点缀色。
            if markedBlock {
                storage.addAttribute(.backgroundColor, value: markColor.withAlphaComponent(0.16), range: range)
                if hasChinese { storage.addAttribute(.foregroundColor, value: primaryTextColor, range: range) }
            }
            if stampLength > 0 {
                storage.addAttributes([
                    .font: NSFont.monospacedDigitSystemFont(ofSize: max(11, baseSize - 5), weight: .medium),
                    .foregroundColor: secondaryTextColor.withAlphaComponent(0.75),
                    .baselineOffset: 1
                ], range: NSRange(location: range.location, length: stampLength))
            }
            if starred {
                storage.addAttribute(.foregroundColor, value: markColor,
                                     range: NSRange(location: range.location + stampLength, length: 1))
            }
        }
        storage.endEditing()
    }

    /// 行首“12:34:56  ”时间戳的长度（UTF-16），没有时为 0。
    private static func stampLength(_ line: String) -> Int {
        let utf16 = Array(line.utf16.prefix(10))
        guard utf16.count == 10 else { return 0 }
        let digits = [0, 1, 3, 4, 6, 7], colons = [2, 5], spaces = [8, 9]
        guard digits.allSatisfy({ (48...57).contains(utf16[$0]) }), colons.allSatisfy({ utf16[$0] == 58 }),
              spaces.allSatisfy({ utf16[$0] == 32 }) else { return 0 }
        return 10
    }

    /// 最新字幕距离可视区域底部留出的空白比例（0 = 贴底，0.45 ≈ 屏幕中间）。
    /// 文字本身仍从上往下排列，只是跟随时最新一行停在设定的高度，不用低头看。
    var latestLineRunway: CGFloat = 0 {
        didSet {
            guard latestLineRunway != oldValue else { return }
            cancelSmoothFollow()
            sizeToFit()
            if followsBottom { resumeFollowing() }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if latestLineRunway > 0, let layoutManager, let textContainer,
           let visible = enclosingScrollView?.contentSize.height {
            let used = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
            size.height = max(newSize.height, ceil(used + visible * latestLineRunway))
        }
        super.setFrameSize(size)
    }

    func resumeFollowing() {
        cancelSmoothFollow()
        followsBottom = true
        let wasUpdating = updating
        updating = true
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        if let scroll = enclosingScrollView {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX,
                                    y: clip.bounds.minY + distanceToBottom(in: clip)))
            scroll.reflectScrolledClipView(clip)
        } else {
            scrollToEndOfDocument(nil)
        }
        updating = wasUpdating
    }

    private func distanceToBottom(in clip: NSClipView) -> CGFloat {
        guard let document = enclosingScrollView?.documentView else { return 0 }
        return document.frame.maxY - clip.bounds.maxY
    }
}
