import Foundation
import XCTest
@testable import Kithra

final class PlaintextTempFileJanitorTests: XCTestCase {
    func testInvalidatedPlaybackPermitCannotCreateOutput() throws {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("playback-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        defer { try? fileManager.removeItem(at: outputURL) }

        let permit = ForegroundPlaintextPermit()
        XCTAssertTrue(permit.invalidate().isEmpty)

        XCTAssertThrowsError(
            try permit.createOutput(at: outputURL) {
                try Data("plaintext".utf8).write(to: outputURL)
            }
        ) { error in
            guard case MediaPipelineError.plaintextProductionInvalidated = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(fileManager.fileExists(atPath: outputURL.path))
    }

    func testPlaybackInvalidationWaitsForWriterAndReturnsExactOutput() throws {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("playback-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        defer { try? fileManager.removeItem(at: outputURL) }

        let permit = ForegroundPlaintextPermit()
        let writerEntered = expectation(description: "writer entered permit")
        let allowWriterToFinish = DispatchSemaphore(value: 0)
        let writerFinished = expectation(description: "writer finished")
        let invalidationFinished = DispatchSemaphore(value: 0)
        let result = LockedURLResult()

        DispatchQueue.global().async {
            defer { writerFinished.fulfill() }
            try? permit.createOutput(at: outputURL) {
                try Data("plaintext".utf8).write(to: outputURL)
                writerEntered.fulfill()
                allowWriterToFinish.wait()
            }
        }
        wait(for: [writerEntered], timeout: 2)

        DispatchQueue.global().async {
            let urls = permit.invalidate()
            result.set(urls)
            invalidationFinished.signal()
        }

        // Invalidation cannot return until the locked output write completes.
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 0.05), .timedOut)
        allowWriterToFinish.signal()
        wait(for: [writerFinished], timeout: 2)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(result.get(), [outputURL.standardizedFileURL])
        try fileManager.removeItem(at: outputURL)
        XCTAssertFalse(fileManager.fileExists(atPath: outputURL.path))
    }

    func testPickerRecordingIsMovedIntoOwnedRawPathAndSourceIsRemoved() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("KithraPickerStagingTests-\(UUID().uuidString)", isDirectory: true)
        let tempRoot = root.appendingPathComponent("Media", isDirectory: true)
        let localRoot = root.appendingPathComponent("Local", isDirectory: true)
        let pickerURL = root.appendingPathComponent("arbitrary-picker-name.MOV")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("captured plaintext".utf8).write(to: pickerURL)
        defer { try? fileManager.removeItem(at: root) }

        let pipeline = DefaultMediaPipeline(
            fileManager: fileManager,
            tempRoot: tempRoot,
            localMediaRoot: localRoot,
            plaintextTempJanitor: KithraPlaintextTempFileJanitor()
        )
        let ownedURL = try pipeline.stagePickerRecording(
            from: pickerURL,
            permit: ForegroundPlaintextPermit()
        )

        XCTAssertFalse(fileManager.fileExists(atPath: pickerURL.path))
        XCTAssertEqual(ownedURL.deletingPathExtension().lastPathComponent.count, 40)
        XCTAssertTrue(ownedURL.lastPathComponent.hasPrefix("raw-"))
        XCTAssertNotNil(UUID(uuidString: String(ownedURL.deletingPathExtension().lastPathComponent.dropFirst(4))))
        XCTAssertEqual(try Data(contentsOf: ownedURL), Data("captured plaintext".utf8))

        try await pipeline.removePlaintextTemporaryFiles([ownedURL, ownedURL])
        XCTAssertFalse(fileManager.fileExists(atPath: ownedURL.path))
    }

    func testInlineRecordingGenerationDiscardCoversPreStartCallback() {
        let lifecycle = InlineRecordingLifecycle()
        let firstGeneration = lifecycle.begin()
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-\(UUID().uuidString).mov")
        XCTAssertTrue(lifecycle.registerOutput(firstURL, generation: firstGeneration))

        let invalidation = lifecycle.discardActive()
        XCTAssertEqual(invalidation?.generation, firstGeneration)
        XCTAssertEqual(invalidation?.outputURLs, [firstURL.standardizedFileURL])
        XCTAssertTrue(lifecycle.isDiscarded(firstGeneration))
        XCTAssertEqual(lifecycle.takeGeneration(for: firstURL), firstGeneration)

        let nextGeneration = lifecycle.begin()
        lifecycle.complete(firstGeneration)
        XCTAssertEqual(lifecycle.currentGeneration, nextGeneration)
        XCTAssertFalse(lifecycle.isDiscarded(nextGeneration))
    }

    func testForegroundInvalidationCancelsOperationAndReturnsEveryExactOutput() throws {
        let permit = ForegroundPlaintextPermit()
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-\(UUID().uuidString).mp4")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbnail-staged-\(UUID().uuidString).jpg")
        let cancellation = LockedBool()

        _ = try permit.beginOperation(
            outputURLs: [firstURL, secondURL],
            cancellation: { cancellation.setTrue() }
        )
        let invalidatedURLs = permit.invalidate()

        XCTAssertTrue(cancellation.get())
        XCTAssertEqual(
            Set(invalidatedURLs),
            Set([firstURL.standardizedFileURL, secondURL.standardizedFileURL])
        )
        XCTAssertThrowsError(try permit.registerOutput(firstURL)) { error in
            guard case MediaPipelineError.plaintextProductionInvalidated = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInvalidationCannotBeFollowedByStartingRegisteredProducer() throws {
        let permit = ForegroundPlaintextPermit()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-\(UUID().uuidString).mp4")
        let cancellation = LockedBool()
        let started = LockedBool()
        let operationID = try permit.beginOperation(
            outputURLs: [outputURL],
            cancellation: { cancellation.setTrue() }
        )

        _ = permit.invalidate()

        XCTAssertTrue(cancellation.get())
        XCTAssertFalse(
            permit.startOperation(operationID) {
                started.setTrue()
            }
        )
        XCTAssertFalse(started.get())
    }

    func testInlineMergeInvalidationCancelsExportAndTracksSegmentAndMerge() {
        let lifecycle = InlineRecordingLifecycle()
        let generation = lifecycle.begin()
        let segmentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-\(UUID().uuidString).mov")
        let mergedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-merged-\(UUID().uuidString).mov")
        let cancellation = LockedBool()

        XCTAssertTrue(lifecycle.registerOutput(segmentURL, generation: generation))
        XCTAssertNotNil(
            lifecycle.beginOperation(
                outputURL: mergedURL,
                generation: generation,
                cancellation: { cancellation.setTrue() }
            )
        )

        let invalidation = lifecycle.discardActive()
        XCTAssertTrue(cancellation.get())
        XCTAssertEqual(invalidation?.generation, generation)
        XCTAssertEqual(
            Set(invalidation?.outputURLs ?? []),
            Set([segmentURL.standardizedFileURL, mergedURL.standardizedFileURL])
        )
        XCTAssertNil(
            lifecycle.beginOperation(
                outputURL: mergedURL,
                generation: generation,
                cancellation: {}
            )
        )
    }

    func testInlineInvalidationPreventsRegisteredMergeFromStarting() throws {
        let lifecycle = InlineRecordingLifecycle()
        let generation = lifecycle.begin()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-merged-\(UUID().uuidString).mov")
        let cancellation = LockedBool()
        let started = LockedBool()
        let operationID = lifecycle.beginOperation(
            outputURL: outputURL,
            generation: generation,
            cancellation: { cancellation.setTrue() }
        )
        XCTAssertNotNil(operationID)

        _ = lifecycle.discardActive()

        XCTAssertTrue(cancellation.get())
        XCTAssertFalse(
            lifecycle.startOperation(
                try XCTUnwrap(operationID),
                generation: generation,
                start: { started.setTrue() }
            )
        )
        XCTAssertFalse(started.get())
    }

    func testInlineOutputRemainsTrackedAcrossDelegateToAppStateHandoff() {
        let lifecycle = InlineRecordingLifecycle()
        let generation = lifecycle.begin()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-\(UUID().uuidString).mov")
        XCTAssertTrue(lifecycle.registerOutput(outputURL, generation: generation))

        // The AV delegate consumes its path lookup before invoking the view,
        // but lifecycle ownership must remain until AppState accepts the URL.
        XCTAssertEqual(lifecycle.takeGeneration(for: outputURL), generation)
        XCTAssertEqual(
            lifecycle.discardActive()?.outputURLs,
            [outputURL.standardizedFileURL]
        )
    }

    func testInvalidatedPickerPermitDeletesValidatedUnstagedSource() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("KithraInvalidPickerTests-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = root.appendingPathComponent("picker.mov")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("plaintext".utf8).write(to: sourceURL)
        defer { try? fileManager.removeItem(at: root) }

        let pipeline = DefaultMediaPipeline(
            fileManager: fileManager,
            tempRoot: root.appendingPathComponent("Media", isDirectory: true),
            localMediaRoot: root.appendingPathComponent("Local", isDirectory: true),
            plaintextTempJanitor: KithraPlaintextTempFileJanitor()
        )
        let permit = ForegroundPlaintextPermit()
        _ = permit.invalidate()

        XCTAssertThrowsError(
            try pipeline.stagePickerRecording(from: sourceURL, permit: permit)
        ) { error in
            guard case MediaPipelineError.plaintextProductionInvalidated = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(fileManager.fileExists(atPath: sourceURL.path))
    }

    func testDirectPlaintextDeletionRejectsNestedOutsideAndSymlinkPaths() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("KithraDirectDeletionTests-\(UUID().uuidString)", isDirectory: true)
        let mediaRoot = root.appendingPathComponent("Media", isDirectory: true)
        let nestedRoot = mediaRoot.appendingPathComponent("Nested", isDirectory: true)
        try fileManager.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let nestedURL = nestedRoot.appendingPathComponent("raw-\(UUID().uuidString).mov")
        let outsideURL = root.appendingPathComponent("raw-\(UUID().uuidString).mov")
        let symlinkTarget = root.appendingPathComponent("target.mov")
        let symlinkURL = mediaRoot.appendingPathComponent("raw-\(UUID().uuidString).mov")
        try Data("nested".utf8).write(to: nestedURL)
        try Data("outside".utf8).write(to: outsideURL)
        try Data("target".utf8).write(to: symlinkTarget)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: symlinkTarget)

        let pipeline = DefaultMediaPipeline(
            fileManager: fileManager,
            tempRoot: mediaRoot,
            localMediaRoot: root.appendingPathComponent("Local", isDirectory: true),
            plaintextTempJanitor: KithraPlaintextTempFileJanitor()
        )
        do {
            try await pipeline.removePlaintextTemporaryFiles([
                nestedURL,
                outsideURL,
                symlinkURL
            ])
            XCTFail("Unowned plaintext paths must be rejected")
        } catch let error as PlaintextTemporaryFileCleanupError {
            XCTAssertEqual(
                Set(error.failedPaths),
                Set([nestedURL.path, outsideURL.path, symlinkURL.path])
            )
        }

        XCTAssertTrue(fileManager.fileExists(atPath: nestedURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: outsideURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: symlinkURL.path))
        XCTAssertEqual(try Data(contentsOf: symlinkTarget), Data("target".utf8))
    }

    func testCleanupIsStrictNonRecursiveAndPreservesActiveFiles() throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root) }

        let segment = fixture.inlineRoot
            .appendingPathComponent("kithra-inline-\(UUID().uuidString).mov")
        let merged = fixture.inlineRoot
            .appendingPathComponent("kithra-inline-merged-\(UUID().uuidString).mov")
        let raw = fixture.mediaRoot
            .appendingPathComponent("raw-\(UUID().uuidString).mov")
        let delivery = fixture.mediaRoot
            .appendingPathComponent("delivery-\(UUID().uuidString).mp4")
        let playback = fixture.mediaRoot
            .appendingPathComponent("playback-\(UUID().uuidString).mp4")
        let stagedThumbnail = fixture.mediaRoot
            .appendingPathComponent("thumbnail-staged-\(UUID().uuidString).jpg")
        let signatureHex = String(repeating: "ab", count: 64)
        let abandonedThumbnail = fixture.mediaRoot.appendingPathComponent(
            "thumb-outgoing-client-\(UUID().uuidString)-auth-\(signatureHex).jpg"
        )
        let activeThumbnail = fixture.mediaRoot.appendingPathComponent(
            "thumb-incoming-server-\(UUID().uuidString)-auth-\(signatureHex).jpg"
        )
        let abandoned = [
            segment,
            merged,
            raw,
            delivery,
            stagedThumbnail,
            abandonedThumbnail
        ]
        for url in abandoned + [playback, activeThumbnail] {
            try Data("plaintext".utf8).write(to: url)
        }
        try fixture.janitor.preserveWhileInUse(playback)
        try fixture.janitor.preserveWhileInUse(activeThumbnail)

        let unrelatedFiles = [
            fixture.inlineRoot.appendingPathComponent("kithra-inline-not-a-uuid.mov"),
            fixture.inlineRoot.appendingPathComponent("kithra-inline-\(UUID().uuidString).mp4"),
            fixture.inlineRoot.appendingPathComponent("unrelated.mov"),
            fixture.mediaRoot.appendingPathComponent("encrypted-\(UUID().uuidString).blob"),
            fixture.mediaRoot.appendingPathComponent("thumb-outgoing-client-cache.jpg"),
            fixture.mediaRoot.appendingPathComponent(
                "thumb-outgoing-client-\(UUID().uuidString)-auth-\(String(repeating: "ab", count: 63)).jpg"
            ),
            fixture.mediaRoot.appendingPathComponent(
                "thumb-incoming-server-\(UUID().uuidString)-auth-\(String(repeating: "AB", count: 64)).jpg"
            ),
            fixture.mediaRoot.appendingPathComponent(
                "thumb-outgoing-client-not-a-uuid-auth-\(signatureHex).jpg"
            )
        ]
        for url in unrelatedFiles {
            try Data("leave me".utf8).write(to: url)
        }

        let nestedRoot = fixture.mediaRoot.appendingPathComponent("nested", isDirectory: true)
        try fixture.fileManager.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        let nestedPlayback = nestedRoot
            .appendingPathComponent("playback-\(UUID().uuidString).mp4")
        try Data("nested plaintext".utf8).write(to: nestedPlayback)

        let directoryWithOwnedName = fixture.inlineRoot
            .appendingPathComponent("kithra-inline-\(UUID().uuidString).mov", isDirectory: true)
        try fixture.fileManager.createDirectory(
            at: directoryWithOwnedName,
            withIntermediateDirectories: true
        )

        let symlinkTarget = fixture.root.appendingPathComponent("outside-target.mov")
        try Data("outside".utf8).write(to: symlinkTarget)
        let ownedLookingSymlink = fixture.inlineRoot
            .appendingPathComponent("kithra-inline-\(UUID().uuidString).mov")
        try fixture.fileManager.createSymbolicLink(
            at: ownedLookingSymlink,
            withDestinationURL: symlinkTarget
        )

        let firstReport = fixture.janitor.cleanupAbandonedFiles(
            fileManager: fixture.fileManager,
            applicationTemporaryRoot: fixture.inlineRoot,
            mediaTemporaryRoot: fixture.mediaRoot
        )

        XCTAssertEqual(Set(firstReport.removedFiles.map(\.standardizedFileURL)), Set(abandoned))
        XCTAssertTrue(firstReport.failedFiles.isEmpty)
        for url in abandoned {
            XCTAssertFalse(fixture.fileManager.fileExists(atPath: url.path))
        }
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: playback.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: activeThumbnail.path))
        for url in unrelatedFiles {
            XCTAssertTrue(fixture.fileManager.fileExists(atPath: url.path))
        }
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: nestedPlayback.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: directoryWithOwnedName.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: ownedLookingSymlink.path))
        XCTAssertEqual(try Data(contentsOf: symlinkTarget), Data("outside".utf8))

        let idempotentReport = fixture.janitor.cleanupAbandonedFiles(
            fileManager: fixture.fileManager,
            applicationTemporaryRoot: fixture.inlineRoot,
            mediaTemporaryRoot: fixture.mediaRoot
        )
        XCTAssertTrue(idempotentReport.removedFiles.isEmpty)
        XCTAssertTrue(idempotentReport.failedFiles.isEmpty)
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: playback.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: activeThumbnail.path))

        fixture.janitor.release(playback)
        fixture.janitor.release(activeThumbnail)
        let releasedReport = fixture.janitor.cleanupAbandonedFiles(
            fileManager: fixture.fileManager,
            applicationTemporaryRoot: fixture.inlineRoot,
            mediaTemporaryRoot: fixture.mediaRoot
        )
        XCTAssertEqual(
            Set(releasedReport.removedFiles.map(\.standardizedFileURL)),
            Set([playback, activeThumbnail])
        )
        XCTAssertTrue(releasedReport.failedFiles.isEmpty)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: playback.path))
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: activeThumbnail.path))
    }

    func testCleanupTreatsMissingRootsAsAlreadyClean() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("KithraMissingJanitorRoots-\(UUID().uuidString)", isDirectory: true)
        let report = KithraPlaintextTempFileJanitor().cleanupAbandonedFiles(
            fileManager: fileManager,
            applicationTemporaryRoot: root.appendingPathComponent("Inline", isDirectory: true),
            mediaTemporaryRoot: root.appendingPathComponent("Media", isDirectory: true)
        )

        XCTAssertTrue(report.removedFiles.isEmpty)
        XCTAssertTrue(report.failedFiles.isEmpty)
    }

    private func makeFixture() throws -> JanitorFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("KithraPlaintextJanitorTests-\(UUID().uuidString)", isDirectory: true)
        let inlineRoot = root.appendingPathComponent("Inline", isDirectory: true)
        let mediaRoot = root.appendingPathComponent("Media", isDirectory: true)
        try fileManager.createDirectory(at: inlineRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        return JanitorFixture(
            fileManager: fileManager,
            root: root,
            inlineRoot: inlineRoot,
            mediaRoot: mediaRoot,
            janitor: KithraPlaintextTempFileJanitor()
        )
    }
}

private struct JanitorFixture {
    let fileManager: FileManager
    let root: URL
    let inlineRoot: URL
    let mediaRoot: URL
    let janitor: KithraPlaintextTempFileJanitor
}

private final class LockedURLResult: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func set(_ urls: [URL]) {
        lock.lock()
        self.urls = urls
        lock.unlock()
    }

    func get() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setTrue() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
