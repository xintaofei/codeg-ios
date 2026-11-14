import Foundation
import Testing
@testable import Codeg

// `src/lib/markdown-local-image.test.ts` (codeg 0.44), case for case, plus the
// `normalizeAbsPath` suite of `src/lib/file-open-target.test.ts`. Inputs are
// the web's verbatim; a JavaScript `"\\"` is a Swift `"\\"` too, so the
// backslash cases read the same.

private typealias L = MarkdownLocalImage

@Suite("local Markdown image paths")
struct LocalImagePathTests {
    @Test("resolves %s under %s", arguments: [
        ("/repo/images/plot.png", "/repo", "images/plot.png"),
        ("./images/plot.png", "/repo", "images/plot.png"),
        ("images/plot.png", "/repo", "images/plot.png"),
        ("file:///repo/images/plot.png", "/repo", "images/plot.png"),
        ("C:/My Project/_tmp/plot.png", "C:/My Project", "_tmp/plot.png"),
        ("/C:/My%20Project/_tmp/plot.png", "C:/My Project", "_tmp/plot.png"),
        ("c:\\MY PROJECT\\images\\plot.png", "C:/My Project", "images/plot.png"),
        ("file:///C:/My%20Project/images/plot.png", "C:/My Project", "images/plot.png"),
        ("file://server/share/project/plot.png", "//server/share/project", "plot.png"),
        ("/repo/%E5%9B%BE%23%3F.png?v=2#preview", "/repo", "图#?.png"),
        ("./images/../plot.svg", "/repo", "plot.svg"),
        ("/plot.avif", "/", "plot.avif"),
        // Joined onto the POSIX root, a relative path must not read as `//…`.
        ("tmp/nanguang-login/login-qr-new.png", "/", "tmp/nanguang-login/login-qr-new.png"),
        ("./plot.png", "/", "plot.png"),
        ("C:/plot.png", "C:/", "plot.png"),
        ("plot.png", "C:/", "plot.png"),
        ("C:/İ/plot.png", "C:/İ", "plot.png"),
        ("c:\\i\\plot.png", "C:/I", "plot.png"),
    ])
    func resolvesUnderRoot(_ c: (String, String, String)) {
        let (source, root, path) = c
        #expect(L.resolve(source, root: root)?.path == path)
    }

    @Test("does not turn %s into a local image", arguments: [
        "https://example.com/image.png",
        "//example.com/image.png",
        "data:image/svg+xml;base64,AAAA",
        "javascript:alert(1).png",
        "blob:https://example.com/image.png",
        "http%3A%2F%2Fexample.com/image.png",
        "C:relative.png",
        "file:///repo/plot.png:secret.png",
        "/repo/%00.png",
        "/repo/%zz.png",
        "\\\\?\\C:\\repo\\plot.png",
    ])
    func refusesNonPaths(_ source: String) {
        #expect(L.localImagePath(source) == nil)
    }

    @Test("resolves %s outside %s to its absolute path", arguments: [
        ("/tmp/nanguang-login/login-qr-new.png", "/repo", "/tmp/nanguang-login/login-qr-new.png"),
        ("../shot.png", "/repo", "/shot.png"),
        ("..\\shot.png", "C:/repo", "C:/shot.png"),
        ("images/%2e%2e/%2e%2e/shot.png", "/repo", "/shot.png"),
        ("/repo-other/shot.png", "/repo", "/repo-other/shot.png"),
        ("/Repo/shot.png", "/repo", "/Repo/shot.png"),
        ("file:///private/shot.png", "/repo", "/private/shot.png"),
        ("D:/repo/shot.png", "C:/repo", "D:/repo/shot.png"),
        ("c:\\Users\\me\\shot.png", "D:/repo", "C:/Users/me/shot.png"),
    ])
    func resolvesOutsideRoot(_ c: (String, String, String)) {
        let (source, root, path) = c
        let name = String(path[path.index(after: path.lastIndex(of: "/")!)...])
        #expect(L.resolve(source, root: root) == L.Target(path: path, name: name, mime: "image/png"))
    }

    @Test("refuses %s under %s", arguments: [
        ("plot.png", ""),
        ("plot.png", "relative/root"),
        ("config.json", "/repo"),
        ("/tmp/notes.txt", "/repo"),
        // A drive or share root matches case-insensitively, and lowercasing `İ`
        // adds a code unit (`i̇`): cut at the root's own length, the rest would
        // name `/plot.png`.
        ("C:/i%CC%87/plot.png", "C:/İ"),
        ("../i%CC%87/plot.png", "//server/share/İ"),
    ])
    func refusesUnderRoot(_ source: String, _ root: String) {
        #expect(L.resolve(source, root: root) == nil)
    }

    // Opening one would make this machine contact the host the reply names.
    @Test("refuses %s under %s: a network share the workspace is not on", arguments: [
        ("file://other/share/secret.png", "//server/share"),
        ("file://attacker.example/share/qr.png", "/repo"),
        ("file://attacker.example/share/qr.png", "C:/repo"),
        // The POSIX root counts `//host/…` as inside it.
        ("file://attacker.example/share/qr.png", "/"),
        ("file:////attacker.example/share/qr.png", "/repo"),
        ("\\\\attacker.example\\share\\qr.png", "C:/repo"),
        ("/\\attacker.example\\share\\qr.png", "/repo"),
        ("%5C%5Cattacker.example%5Cshare%5Cqr.png", "/repo"),
        ("%2F%2Fattacker.example%2Fshare%2Fqr.png", "/repo"),
    ])
    func refusesForeignShares(_ source: String, _ root: String) {
        // Refused by the share test itself, not earlier as a non-path.
        let path = L.localImagePath(source)
        #expect(path?.hasPrefix("//attacker.example/") == true || path?.hasPrefix("//other/") == true)
        #expect(L.resolve(source, root: root) == nil)
    }
}

@Suite("local Markdown image paths without a root")
struct LocalImagePathWithoutRootTests {
    @Test("resolves %s to its absolute path", arguments: [
        ("/tmp/login.png", "/tmp/login.png"),
        ("/tmp/a/../login.png", "/tmp/login.png"),
        ("file:///tmp/login.png", "/tmp/login.png"),
        ("c:\\Users\\me\\login.png", "C:/Users/me/login.png"),
    ])
    func resolvesAbsolute(_ source: String, _ path: String) {
        #expect(L.resolve(source, root: nil) == L.Target(path: path, name: "login.png", mime: "image/png"))
    }

    @Test("refuses %s", arguments: [
        // Nothing to resolve a relative path against.
        "login.png",
        "./login.png",
        "../login.png",
        "/tmp/notes.txt",
        // A network share: opening it would make this machine contact the host.
        "file://attacker.example/share/qr.png",
        "\\\\attacker.example\\share\\qr.png",
        "%2F%2Fattacker.example%2Fshare%2Fqr.png",
    ])
    func refuses(_ source: String) {
        #expect(L.resolve(source, root: nil) == nil)
    }
}

@Suite("localImageMime")
struct LocalImageMimeTests {
    @Test("knows %s as %s", arguments: [
        ("/tmp/login-qr-new.png", "image/png"),
        ("C:\\shots\\Shot.JPG", "image/jpeg"),
        ("~/a.jpeg", "image/jpeg"),
        ("icon.svg", "image/svg+xml"),
        ("photo.webp", "image/webp"),
    ])
    func knows(_ path: String, _ mime: String) {
        #expect(L.mime(path) == mime)
    }

    @Test("knows %s as no image", arguments: [
        "notes.md",
        "archive.png.zip",
        "/repo/shots.png/README",
        "Makefile",
        // Extensions that name an `Object.prototype` key on the web.
        "x.constructor",
        "x.__proto__",
        "",
    ])
    func knowsNoImage(_ path: String) {
        #expect(L.mime(path) == nil)
    }
}

@Suite("normalizeAbsPath")
struct NormalizeAbsPathTests {
    @Test func normalizesSlashesAndStripsTrailingSlashes() {
        #expect(L.normalizeAbsPath("/repo/src/") == "/repo/src")
        #expect(L.normalizeAbsPath("\\repo\\src\\a.ts") == "/repo/src/a.ts")
        #expect(L.normalizeAbsPath("/repo//") == "/repo")
    }

    @Test func keepsTheBareRoots() {
        #expect(L.normalizeAbsPath("/") == "/")
        #expect(L.normalizeAbsPath("C:/") == "C:/")
        #expect(L.normalizeAbsPath("c:\\") == "C:/")
    }

    @Test func upperCasesWindowsDriveLetters() {
        #expect(L.normalizeAbsPath("c:/Repo/x.ts") == "C:/Repo/x.ts")
    }

    @Test func resolvesDotSegments() {
        #expect(L.normalizeAbsPath("/repo/src/../a.ts") == "/repo/a.ts")
        #expect(L.normalizeAbsPath("/repo/./a.ts") == "/repo/a.ts")
        #expect(L.normalizeAbsPath("/repo//src///a.ts") == "/repo/src/a.ts")
        #expect(L.normalizeAbsPath("C:/repo/../x.ts") == "C:/x.ts")
    }

    @Test func floorsDotDotAtTheRoot() {
        #expect(L.normalizeAbsPath("/repo/../etc/passwd") == "/etc/passwd")
        #expect(L.normalizeAbsPath("/a/../../x") == "/x")
    }

    @Test func preservesTheUNCPrefix() {
        #expect(L.normalizeAbsPath("//server/share/x.ts") == "//server/share/x.ts")
        #expect(L.normalizeAbsPath("\\\\server\\share\\x.ts") == "//server/share/x.ts")
    }

    @Test func floorsDotDotAtTheShareRoot() {
        #expect(L.normalizeAbsPath("//server/share/../x") == "//server/share/x")
        #expect(L.normalizeAbsPath("//server/share/sub/../x") == "//server/share/x")
        #expect(L.normalizeAbsPath("//server/share/..") == "//server/share")
    }

    @Test func dropsTheURLSlashBeforeADrive() {
        #expect(L.normalizeAbsPath("/C:/My Project/x.png") == "C:/My Project/x.png")
    }
}

@Suite("file: URLs")
struct FileURLPathTests {
    @Test func readsHostsAndDrives() {
        #expect(L.fileURLPath("file:///tmp/a.png") == "/tmp/a.png")
        #expect(L.fileURLPath("file://localhost/tmp/a.png") == "/tmp/a.png")
        #expect(L.fileURLPath("file://Server/share/a.png") == "//server/share/a.png")
        #expect(L.fileURLPath("file://C:/x/a.png") == "/C:/x/a.png")
        #expect(L.fileURLPath("file:/tmp/a.png") == "/tmp/a.png")
        #expect(L.fileURLPath("file:///tmp/a.png?v=1#top") == "/tmp/a.png")
    }

    @Test func resolvesDotSegmentsWithTheHostInPlace() {
        #expect(L.fileURLPath("file://server/share/../other/shot.png") == "//server/other/shot.png")
        #expect(L.fileURLPath("file:///a/b/%2e%2e/c.png") == "/a/c.png")
        #expect(L.fileURLPath("file:///a/./b.png") == "/a/b.png")
        // A drive letter is never popped, and `C|` is the legacy `C:`.
        #expect(L.fileURLPath("file:///C:/../x.png") == "/C:/x.png")
        #expect(L.fileURLPath("file:///C|/x.png") == "/C:/x.png")
        #expect(L.fileURLPath("file:///") == "/")
    }

    @Test func aDotDotOutOfTheShareLeavesIt() {
        // `new URL` resolves the `..` against the share, so this names another
        // share on that host — not a file inside the workspace's share.
        #expect(L.resolve("file://server/share/../other/shot.png", root: "//server/share") == nil)
    }

    @Test func refusesHostsTheURLParserRejects() {
        #expect(L.fileURLPath("file://host:8080/a.png") == nil)
        #expect(L.fileURLPath("file://user@host/a.png") == nil)
    }
}
