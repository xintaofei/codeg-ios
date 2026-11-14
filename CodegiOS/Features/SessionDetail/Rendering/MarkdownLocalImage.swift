import Foundation

/// Which file a Markdown image destination names — a port of the web's
/// `src/lib/markdown-local-image.ts` (`localImagePath` / `resolveLocalImage` /
/// `localImageMime`) and the two path helpers it leans on
/// (`file-path-display.ts` `isAbsoluteFilePath`, `file-open-target.ts`
/// `normalizeAbsPath` / `isPathUnderRoot`), codeg 0.44.
///
/// Pure and deliberately literal: the rules decide which files a reply may make
/// this device read, so they follow the web line by line instead of leaning on
/// `URL`/`NSString` path APIs, which normalise differently. Everything is done
/// on Unicode scalars or UTF-16 code units — the web compares and slices
/// JavaScript strings, and the `İ` cases in its tests only come out the same
/// that way (lowercasing `İ` adds a code unit).
enum MarkdownLocalImage {
    /// `LOCAL_IMAGE_MAX_BYTES`: the most either reader returns.
    static let maxBytes = 8 * 1024 * 1024

    /// The longest base64 string `maxBytes` of file can encode to; anything
    /// longer is refused (`Math.ceil(LOCAL_IMAGE_MAX_BYTES / 3) * 4`).
    static let maxBase64Length = (maxBytes + 2) / 3 * 4

    /// A resolved image file. `path` is relative to the transcript's root for an
    /// image inside it and absolute for one outside it.
    struct Target: Hashable, Sendable {
        let path: String
        let name: String
        let mime: String
    }

    private static let mimes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif": "image/gif",
        "svg": "image/svg+xml",
        "avif": "image/avif",
        "bmp": "image/bmp",
        "ico": "image/x-icon",
    ]

    /// The MIME type of an image file by its extension; nil for any other file.
    static func mime(_ path: String) -> String? {
        // `path.split(".").pop()`: everything after the last dot, or the whole
        // string when there is none.
        let scalars = path.unicodeScalars
        let ext: String
        if let dot = scalars.lastIndex(of: ".") {
            ext = String(scalars[scalars.index(after: dot)...])
        } else {
            ext = path
        }
        return mimes[ext.lowercased()]
    }

    // MARK: - localImagePath

    /// The path a destination names, or nil when it is not a local file
    /// reference at all (a URL with another scheme, a fragment, a
    /// protocol-relative URL, a device path…).
    static func localImagePath(_ source: String) -> String? {
        var path = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || hasPrefix(path, "//") || hasPrefix(path, "#") { return nil }
        // `/^[\\/]{2}[?.][\\/]/` — a `\\?\` or `\\.\` device path.
        if isDevicePath(Array(path.unicodeScalars), slashes: ["/", "\\"]) { return nil }

        if hasSchemePrefix(path, "file:") {
            guard let fromURL = fileURLPath(path) else { return nil }
            path = fromURL
        } else {
            // A drive letter is a path, not a URI scheme. Drive-relative C:foo is
            // deliberately excluded because it depends on process-global state.
            if startsWithScheme(path), !startsWithDrive(path, slash: ["/", "\\"]) { return nil }
            path = beforeQueryOrFragment(path)
        }

        guard let decoded = decodeURIComponent(path) else { return nil }
        path = decoded
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return nil }
        path = slashed(path)

        // Device paths and NTFS alternate data streams, plus schemes hidden
        // behind percent encoding: only the drive-designator colon is valid.
        if isDevicePath(Array(path.unicodeScalars), slashes: ["/"]) { return nil }
        if stripLeadingDrive(path).unicodeScalars.contains(":") { return nil }
        return path
    }

    // MARK: - resolveLocalImage

    /// The image file a Markdown destination names, resolved against the
    /// transcript's root (`nil` = the folder is unknown, when only an absolute
    /// path names a file). Nil for anything that is not an image file this
    /// device may read: an unknown extension, a relative path with no root, or a
    /// network share other than the one the workspace is on.
    static func resolve(_ source: String, root rootPath: String?) -> Target? {
        guard let path = localImagePath(source), let type = Self.mime(path) else { return nil }

        guard let rootPath else {
            guard isAbsoluteFilePath(path) else { return nil }
            let absolute = normalizeAbsPath(path)
            // A network share: see below.
            if hasPrefix(absolute, "//") { return nil }
            return Target(path: absolute, name: fileName(absolute), mime: type)
        }

        let root = normalizeAbsPath(rootPath)
        guard isAbsoluteFilePath(root) else { return nil }
        // Not `${root}/…`: under the POSIX root that reads `//…`, a network share.
        let prefix = hasSuffix(root, "/") ? root : root + "/"
        let absolute = normalizeAbsPath(isAbsoluteFilePath(path) ? path : prefix + path)
        let inRoot = isPathUnderRoot(absolute, root)
        // A network share other than the one the workspace is on: opening it
        // would make this machine contact the host the reply names. The POSIX
        // root `/` counts `//host/…` as inside it, so the share test is on the
        // root itself.
        if hasPrefix(absolute, "//"), !(inRoot && hasPrefix(root, "//")) { return nil }
        let name = fileName(absolute)
        if inRoot {
            // A drive or share root matches case-insensitively, and lowercasing
            // can change a string's length (`İ` → `i̇`): cut only where the root
            // really ends, or the rest names another file.
            let units = Array(absolute.utf16)
            let prefixLength = prefix.utf16.count
            let head = String(decoding: units.prefix(prefixLength), as: UTF16.self)
            guard Array(head.lowercased().utf16) == Array(prefix.lowercased().utf16) else { return nil }
            let rest = String(decoding: units.dropFirst(prefixLength), as: UTF16.self)
            return Target(path: rest, name: name, mime: type)
        }
        return Target(path: absolute, name: name, mime: type)
    }

    // MARK: - Path helpers (file-path-display.ts / file-open-target.ts)

    /// POSIX `/…` or Windows `C:\…` / `C:/…`.
    static func isAbsoluteFilePath(_ path: String) -> Bool {
        let normalized = slashed(path)
        return hasPrefix(normalized, "/") || startsWithDrive(normalized, slash: ["/", "\\"])
    }

    /// Forward slashes; `.`/`..` resolved and floored at the root (a UNC
    /// `//server/share` keeps its two designator segments); duplicate
    /// separators collapsed; no trailing slash except on a bare root; the drive
    /// letter uppercased. A relative path only loses trailing slashes.
    static func normalizeAbsPath(_ path: String) -> String {
        var normalized = slashed(path.trimmingCharacters(in: .whitespacesAndNewlines))
        // URL-style Windows paths ("/C:/x"): the leading slash is a URL artifact.
        var scalars = Array(normalized.unicodeScalars)
        if scalars.count >= 4, scalars[0] == "/", isASCIILetter(scalars[1]),
           scalars[2] == ":", scalars[3] == "/" {
            scalars.removeFirst()
        }
        let hasDrive = scalars.count >= 2 && isASCIILetter(scalars[0]) && scalars[1] == ":"
        if hasDrive, ("a"..."z").contains(scalars[0]), let upper = Unicode.Scalar(scalars[0].value - 32) {
            scalars[0] = upper
        }
        normalized = String(String.UnicodeScalarView(scalars))

        let isUnc = !hasDrive && hasPrefix(normalized, "//")
        let isPosix = !hasDrive && !isUnc && hasPrefix(normalized, "/")
        guard hasDrive || isUnc || isPosix else {
            // Relative (or otherwise unrooted): only strip trailing slashes.
            var rest = scalars
            while rest.count > 1, rest.last == "/" { rest.removeLast() }
            return String(String.UnicodeScalarView(rest))
        }

        let body = hasDrive ? Array(scalars.dropFirst(2)) : scalars
        let floor = isUnc ? 2 : 0
        var parts: [String] = []
        for segment in body.split(separator: "/", omittingEmptySubsequences: false) {
            let s = String(String.UnicodeScalarView(segment))
            if s.isEmpty || s == "." { continue }
            if s == ".." {
                if parts.count > floor { parts.removeLast() }
                continue
            }
            parts.append(s)
        }
        let prefix = hasDrive ? String(String.UnicodeScalarView(scalars.prefix(2))) + "/" : (isUnc ? "//" : "/")
        return parts.isEmpty ? prefix : prefix + parts.joined(separator: "/")
    }

    /// Boundary-safe containment: `absPath` is strictly inside `rootPath`. Drive
    /// and UNC roots compare case-insensitively; the root is not under itself.
    static func isPathUnderRoot(_ absPath: String, _ rootPath: String) -> Bool {
        let path = normalizeAbsPath(absPath)
        let root = normalizeAbsPath(rootPath)
        guard !root.isEmpty, isAbsoluteFilePath(root) else { return false }
        let prefix = hasSuffix(root, "/") ? root : root + "/"
        let prefixScalars = Array(prefix.unicodeScalars)
        let driveRoot = prefixScalars.count >= 2 && isASCIILetter(prefixScalars[0]) && prefixScalars[1] == ":"
        if driveRoot || hasPrefix(prefix, "//") {
            return hasPrefix(path.lowercased(), prefix.lowercased())
        }
        return hasPrefix(path, prefix)
    }

    // MARK: - file: URLs

    /// `new URL(path)` → `url.host ? "//" + host + pathname : pathname`, for the
    /// subset of the WHATWG file-URL grammar a Markdown destination can carry:
    /// tabs/newlines dropped, `\` read as `/`, the query and fragment cut,
    /// `localhost` read as no host, a drive letter in the host slot read as
    /// path, a host the URL parser would reject (a port, userinfo, a forbidden
    /// code point) refused, and dot segments resolved. The pathname keeps its
    /// other percent escapes — `localImagePath` decodes them next, as on the web.
    static func fileURLPath(_ input: String) -> String? {
        var scalars = Array(input.unicodeScalars)
        // Leading/trailing C0 control or space, then every ASCII tab or newline.
        while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
        while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
        scalars.removeAll { $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard scalars.count >= 5,
              String(String.UnicodeScalarView(scalars.prefix(5))).lowercased() == "file:" else { return nil }
        let backslash: Unicode.Scalar = "\\", slash: Unicode.Scalar = "/"
        var rest: [Unicode.Scalar] = scalars.dropFirst(5).map { $0 == backslash ? slash : $0 }
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            rest = Array(rest[..<cut])
        }

        var host = ""
        var pathScalars: [Unicode.Scalar]
        if rest.count >= 2, rest[0] == "/", rest[1] == "/" {
            let afterSlashes = Array(rest.dropFirst(2))
            let hostEnd = afterSlashes.firstIndex(of: "/") ?? afterSlashes.count
            let authority = Array(afterSlashes[..<hostEnd])
            let remainder = Array(afterSlashes[hostEnd...])
            if isWindowsDriveLetter(authority) {
                // `file://C:/x` — the "host" is the drive, part of the path.
                pathScalars = ["/"] + authority + remainder
            } else {
                guard let parsed = fileHost(authority) else { return nil }
                host = parsed
                pathScalars = remainder
            }
        } else {
            pathScalars = rest
        }
        if pathScalars.first == "/" { pathScalars.removeFirst() }

        // The path state: one segment per `/`, dot segments (percent-encoded
        // ones too) resolved as they come and *with the host in place* — so
        // `file://server/share/../x` leaves the share, as `new URL` makes it,
        // rather than being floored at the share by `normalizeAbsPath` later.
        // A leading drive letter (`C|` is the legacy `C:`) is never popped,
        // and clears the host.
        var segments: [String] = []
        let pieces = pathScalars.split(separator: "/", omittingEmptySubsequences: false)
        for (index, piece) in pieces.enumerated() {
            let atEnd = index == pieces.count - 1
            let segment = String(String.UnicodeScalarView(piece))
            switch segment.lowercased() {
            case "..", ".%2e", "%2e.", "%2e%2e":
                let onlyDrive = segments.count == 1 && isNormalizedDriveLetter(segments[0])
                if !segments.isEmpty, !onlyDrive { segments.removeLast() }
                if atEnd { segments.append("") }
            case ".", "%2e":
                if atEnd { segments.append("") }
            default:
                var drive = Array(piece)
                if segments.isEmpty, isWindowsDriveLetter(drive) {
                    drive[1] = ":"
                    host = ""
                    segments.append(String(String.UnicodeScalarView(drive)))
                } else {
                    segments.append(segment)
                }
            }
        }
        let pathname = "/" + segments.joined(separator: "/")
        return host.isEmpty ? pathname : "//" + host + pathname
    }

    /// A file URL's host: percent-decoded, ASCII-lowercased, `localhost` → "".
    /// Nil where the WHATWG host parser fails.
    private static func fileHost(_ authority: [Unicode.Scalar]) -> String? {
        if authority.isEmpty { return "" }
        let raw = String(String.UnicodeScalarView(authority))
        if raw.hasPrefix("[") {
            // An IPv6 literal — opaque here; it still names a remote host.
            guard raw.hasSuffix("]") else { return nil }
            return raw.lowercased()
        }
        guard let decoded = decodeURIComponent(raw) else { return nil }
        let forbidden: Set<Unicode.Scalar> = [
            " ", "#", "%", "/", ":", "<", ">", "?", "@", "[", "\\", "]", "^", "|",
        ]
        for u in decoded.unicodeScalars where u.value <= 0x1F || u.value == 0x7F || forbidden.contains(u) {
            return nil
        }
        let host = decoded.lowercased()
        return host == "localhost" ? "" : host
    }

    // MARK: - Small string tools

    /// `decodeURIComponent`: `%XX` sequences decode as UTF-8; a `%` without two
    /// hex digits, or bytes that are not UTF-8, fail (nil).
    static func decodeURIComponent(_ s: String) -> String? {
        guard s.utf8.contains(UInt8(ascii: "%")) else { return s }
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%") {
                guard i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) else {
                    return nil
                }
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(bytes: out, encoding: .utf8)
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Every `\` read as `/`.
    static func slashed(_ s: String) -> String {
        guard s.unicodeScalars.contains("\\") else { return s }
        let backslash: Unicode.Scalar = "\\", slash: Unicode.Scalar = "/"
        return String(String.UnicodeScalarView(s.unicodeScalars.map { $0 == backslash ? slash : $0 }))
    }

    /// The text after the last `/` (all of it when there is none).
    private static func fileName(_ path: String) -> String {
        let scalars = path.unicodeScalars
        guard let slash = scalars.lastIndex(of: "/") else { return path }
        return String(scalars[scalars.index(after: slash)...])
    }

    /// `path.split(/[?#]/, 1)[0]`.
    private static func beforeQueryOrFragment(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let cut = scalars.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return s }
        return String(scalars[..<cut])
    }

    /// `/^[a-z][a-z\d+.-]*:/i`.
    private static func startsWithScheme(_ s: String) -> Bool {
        var first = true
        for u in s.unicodeScalars {
            if first {
                guard isASCIILetter(u) else { return false }
                first = false
                continue
            }
            if u == ":" { return true }
            guard isASCIILetter(u) || ("0"..."9").contains(u) || u == "+" || u == "." || u == "-" else { return false }
        }
        return false
    }

    /// `/^file:/i`.
    private static func hasSchemePrefix(_ s: String, _ scheme: String) -> Bool {
        let head = String(String.UnicodeScalarView(s.unicodeScalars.prefix(scheme.unicodeScalars.count)))
        return head.lowercased() == scheme
    }

    /// `/^[a-z]:[\\/]/i` with the given separators.
    private static func startsWithDrive(_ s: String, slash: Set<Unicode.Scalar>) -> Bool {
        let head = Array(s.unicodeScalars.prefix(3))
        return head.count == 3 && isASCIILetter(head[0]) && head[1] == ":" && slash.contains(head[2])
    }

    /// `path.replace(/^\/?[a-z]:\//i, "")`.
    private static func stripLeadingDrive(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        let offset = scalars.first == "/" ? 1 : 0
        if scalars.count >= offset + 3, isASCIILetter(scalars[offset]),
           scalars[offset + 1] == ":", scalars[offset + 2] == "/" {
            scalars.removeFirst(offset + 3)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Two separators, `?` or `.`, a separator: `\\?\`, `//./`.
    private static func isDevicePath(_ s: [Unicode.Scalar], slashes: Set<Unicode.Scalar>) -> Bool {
        s.count >= 4 && slashes.contains(s[0]) && slashes.contains(s[1])
            && (s[2] == "?" || s[2] == ".") && slashes.contains(s[3])
    }

    /// A drive letter: an ASCII letter and `:` or `|`.
    private static func isWindowsDriveLetter(_ s: [Unicode.Scalar]) -> Bool {
        s.count == 2 && isASCIILetter(s[0]) && (s[1] == ":" || s[1] == "|")
    }

    /// A drive letter spelled with `:`.
    private static func isNormalizedDriveLetter(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        return scalars.count == 2 && isASCIILetter(scalars[0]) && scalars[1] == ":"
    }

    private static func isASCIILetter(_ u: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(u) || ("A"..."Z").contains(u)
    }

    /// `String.prototype.startsWith`: code-unit exact, unlike `hasPrefix`
    /// (which compares grapheme clusters under canonical equivalence).
    private static func hasPrefix(_ s: String, _ prefix: String) -> Bool {
        s.utf16.starts(with: prefix.utf16)
    }

    private static func hasSuffix(_ s: String, _ suffix: String) -> Bool {
        s.utf16.reversed().starts(with: suffix.utf16.reversed())
    }
}
