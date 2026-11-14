import Foundation
import Testing
@testable import Codeg

// The "local image reads" suite of `src/lib/markdown-local-image.test.ts`
// (codeg 0.44): the read queue (`MarkdownImageReadQueue`) and the bounded read
// itself (`MarkdownImageLoader.readBytes`), plus which destinations may load.

/// Reads that park until the test lets them finish, in the order they began.
private actor ParkedReads {
    private(set) var started: [String] = []
    private var parked: [CheckedContinuation<Data?, Never>] = []

    func read(_ key: String) async -> Data? {
        started.append(key)
        return await withCheckedContinuation { parked.append($0) }
    }

    /// Finish the oldest read still parked.
    func finishNext(_ value: Data?) {
        parked.removeFirst().resume(returning: value)
    }

    var parkedCount: Int { parked.count }
}

/// Poll until `condition` holds (or give up after ~2 s).
private func until(_ condition: () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private actor CallLog {
    private(set) var calls: [String] = []
    func add(_ call: String) { calls.append(call) }
}

private struct Refused: Error {}

@Suite("local image reads")
struct MarkdownImageReadTests {
    @Test func deduplicatesInFlightReadsButReReadsALaterScreenshotAtTheSamePath() async {
        let queue = MarkdownImageReadQueue(limit: 4)
        let reads = ParkedReads()
        let read: @Sendable () async -> Data? = { await reads.read("preview.png") }

        let first = Task { await queue.data(for: "preview.png", read: read) }
        await until { await reads.started.count == 1 }
        let second = Task { await queue.data(for: "preview.png", read: read) }
        await until { await queue.joinedReads == 1 }
        #expect(await reads.started.count == 1)

        await reads.finishNext(Data("first".utf8))
        #expect(await first.value == Data("first".utf8))
        #expect(await second.value == Data("first".utf8))

        let later = Task { await queue.data(for: "preview.png", read: read) }
        await until { await reads.started.count == 2 }
        #expect(await reads.started.count == 2)
        await reads.finishNext(Data("second".utf8))
        #expect(await later.value == Data("second".utf8))
    }

    @Test func limitsConcurrentReadsAndReleasesSlotsAfterAFailedRead() async {
        let queue = MarkdownImageReadQueue(limit: 4)
        let reads = ParkedReads()
        let pending = (0..<7).map { i in
            Task { await queue.data(for: "\(i).png") { await reads.read("\(i).png") } }
        }
        await until {
            let started = await reads.started.count
            let waiting = await queue.waitingCount
            return started == 4 && waiting == 3
        }
        #expect(await reads.started.count == 4)
        #expect(await queue.waitingCount == 3)

        // A failed read (nil) frees its slot for the next request in line.
        await reads.finishNext(nil)
        await until { await reads.started.count == 5 }
        #expect(await reads.started.count == 5)

        for _ in 0..<6 {
            await until { await reads.parkedCount > 0 }
            await reads.finishNext(Data("cGljdHVyZQ==".utf8))
        }
        var finished = 0
        for task in pending {
            if await task.value != nil { finished += 1 }
        }
        #expect(finished == 6)
        #expect(await reads.started.count == 7)
    }

    @Test func readsAnImageOutsideTheRootByItsAbsolutePathWithTheSameBound() async {
        let log = CallLog()
        let tooLong = String(repeating: "A", count: MarkdownLocalImage.maxBase64Length + 1)
        let readers = MarkdownImageLoader.Readers(
            readWorkspaceFile: { root, path, max in
                await log.add("workspace \(root) \(path) \(max)")
                return "cXI="
            },
            readFile: { path, max in
                await log.add("file \(path) \(max)")
                return path.hasSuffix("large.png") ? tooLong : "cXI="
            },
            fetchRemote: { _, _ in nil }
        )
        func local(_ path: String) -> MarkdownImageTarget {
            .local(MarkdownLocalImage.Target(path: path, name: "x.png", mime: "image/png"))
        }
        let max = MarkdownLocalImage.maxBytes
        #expect(await MarkdownImageLoader.readBytes(local("/tmp/qr.png"), root: "/repo", readers: readers) == Data("qr".utf8))
        #expect(await MarkdownImageLoader.readBytes(local("C:/Users/me/qr.png"), root: "/repo", readers: readers) == Data("qr".utf8))
        #expect(await MarkdownImageLoader.readBytes(local("/tmp/large.png"), root: "/repo", readers: readers) == nil)
        #expect(await log.calls == [
            "file /tmp/qr.png \(max)",
            "file C:/Users/me/qr.png \(max)",
            "file /tmp/large.png \(max)",
        ])
    }

    @Test func readsInsideTheRootRelativeToIt() async {
        let log = CallLog()
        let readers = MarkdownImageLoader.Readers(
            readWorkspaceFile: { root, path, max in
                await log.add("workspace \(root) \(path) \(max)")
                return "cXI="
            },
            readFile: { _, _ in "cXI=" },
            fetchRemote: { _, _ in nil }
        )
        let target = MarkdownImageTarget.local(.init(path: "images/plot.png", name: "plot.png", mime: "image/png"))
        #expect(await MarkdownImageLoader.readBytes(target, root: "/repo", readers: readers) == Data("qr".utf8))
        #expect(await log.calls == ["workspace /repo images/plot.png \(MarkdownLocalImage.maxBytes)"])
    }

    @Test func readsOnlyAbsolutePathsWhenThereIsNoRoot() async {
        let log = CallLog()
        let readers = MarkdownImageLoader.Readers(
            readWorkspaceFile: { _, path, _ in
                await log.add("workspace \(path)")
                return "cXI="
            },
            readFile: { path, _ in
                await log.add("file \(path)")
                return "cXI="
            },
            fetchRemote: { _, _ in nil }
        )
        let absolute = MarkdownImageTarget.local(.init(path: "/tmp/qr.png", name: "qr.png", mime: "image/png"))
        let relative = MarkdownImageTarget.local(.init(path: "qr.png", name: "qr.png", mime: "image/png"))
        #expect(await MarkdownImageLoader.readBytes(absolute, root: nil, readers: readers) == Data("qr".utf8))
        #expect(await MarkdownImageLoader.readBytes(relative, root: nil, readers: readers) == nil)
        #expect(await log.calls == ["file /tmp/qr.png"])
    }

    @Test func boundsReturnedDataAndHandlesEmptyOrRefusedReadsWithoutThrowing() async {
        let tooLong = String(repeating: "A", count: MarkdownLocalImage.maxBase64Length + 1)
        func readers(_ answer: @escaping @Sendable () throws -> String) -> MarkdownImageLoader.Readers {
            MarkdownImageLoader.Readers(
                readWorkspaceFile: { _, _, _ in try answer() },
                readFile: { _, _ in try answer() },
                fetchRemote: { _, _ in nil }
            )
        }
        let target = MarkdownImageTarget.local(.init(path: "large.png", name: "large.png", mime: "image/png"))
        #expect(await MarkdownImageLoader.readBytes(target, root: "/repo", readers: readers { tooLong }) == nil)
        #expect(await MarkdownImageLoader.readBytes(target, root: "/repo", readers: readers { "" }) == nil)
        #expect(await MarkdownImageLoader.readBytes(target, root: "/repo", readers: readers { throw Refused() }) == nil)
    }

    @Test func theBoundIsEightMebibytesOfFile() {
        #expect(MarkdownLocalImage.maxBytes == 8_388_608)
        #expect(MarkdownLocalImage.maxBase64Length == 11_184_812)
    }
}

@Suite("which Markdown images load")
struct MarkdownImageTargetTests {
    private func ref(_ source: String, escape: Bool = false) -> MarkdownImageRef {
        MarkdownImageRef(alt: "x", source: source, link: nil, escapeInDestination: escape)
    }

    @Test func remoteImagesAreHTTPOnly() {
        #expect(MarkdownImageTarget.resolve(ref("https://example.com/preview.png"), root: "/repo")
                == .remote(URL(string: "https://example.com/preview.png")!))
        #expect(MarkdownImageTarget.resolve(ref("http://example.com/a.png"), root: nil)
                == .remote(URL(string: "http://example.com/a.png")!))
        for source in ["data:image/png;base64,AAAA", "javascript:alert(1)", "ftp://example.com/a.png",
                       "//example.com/a.png", "blob:https://example.com/a.png", ""] {
            #expect(MarkdownImageTarget.resolve(ref(source), root: "/repo") == nil, "\(source)")
        }
    }

    @Test func localImagesResolveAgainstTheTranscriptsFolder() {
        #expect(MarkdownImageTarget.resolve(ref("./images/preview.png"), root: "/repo")
                == .local(.init(path: "images/preview.png", name: "preview.png", mime: "image/png")))
        // Never the active workspace when the transcript's own folder is unknown.
        #expect(MarkdownImageTarget.resolve(ref("./preview.png"), root: nil) == nil)
        #expect(MarkdownImageTarget.resolve(ref("./secret.json"), root: "/repo") == nil)
        #expect(MarkdownImageTarget.resolve(ref("file://attacker.example/share/qr.png"), root: "/repo") == nil)
    }

    @Test func refusesADestinationThatMayHaveLostASeparator() {
        #expect(MarkdownImageTarget.resolve(ref("C:\\repo\\shots.preview.png", escape: true), root: "C:/repo") == nil)
        #expect(MarkdownImageTarget.resolve(ref("C:\\repo\\a\\b.png"), root: "C:/repo")
                == .local(.init(path: "a/b.png", name: "b.png", mime: "image/png")))
    }

    @Test func svgFallsBackToItsLabel() {
        #expect(MarkdownImageTarget.resolve(ref("./plot.svg"), root: "/repo")?.isSVG == true)
        #expect(MarkdownImageTarget.resolve(ref("https://e.com/a.SVG"), root: nil)?.isSVG == true)
        #expect(MarkdownImageTarget.resolve(ref("./plot.png"), root: "/repo")?.isSVG == false)
    }

    @MainActor
    @Test func labelIsAltThenNameThenSource() {
        let target = MarkdownImageTarget.local(.init(path: "a/b.png", name: "b.png", mime: "image/png"))
        #expect(MarkdownImageBlock.label(alt: "Shot", target: target, source: "a/b.png") == "Shot")
        #expect(MarkdownImageBlock.label(alt: "", target: target, source: "a/b.png") == "b.png")
        #expect(MarkdownImageBlock.label(alt: "", target: nil, source: "./x.json") == "./x.json")
    }
}
