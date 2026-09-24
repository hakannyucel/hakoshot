import Foundation
import Testing
@testable import HakoKit

@Suite("StudioReducer")
struct StudioReducerTests {
    static func state() -> StudioEditorState { StudioEditorState(project: V1StudioFixture.project()) }

    @Test func timelineEdits() {
        var s = Self.state()
        StudioReducer.reduce(&s, .setTrim(EditTimeRange(start: 0.8, end: -3)))
        #expect(s.project.edit.trim == EditTimeRange(start: 0, end: 0.8))
        StudioReducer.reduce(&s, .setTrim(EditTimeRange(start: 0, end: 5)))
        #expect(s.project.edit.trim == nil) // whole clip = no trim

        StudioReducer.reduce(&s, .addCut(EditTimeRange(start: 0.45, end: 0.6)))
        #expect(s.project.edit.cuts == [EditTimeRange(start: 0.4, end: 0.6)]) // merged with 0.4–0.5
        StudioReducer.reduce(&s, .addCut(EditTimeRange(start: 0.1, end: 0.2)))
        #expect(s.project.edit.cuts.count == 2 && s.project.edit.cuts[0].start == 0.1)
        StudioReducer.reduce(&s, .removeCut(EditTimeRange(start: 0.1, end: 0.2)))
        #expect(s.project.edit.cuts == [EditTimeRange(start: 0.4, end: 0.6)])
        let before = s
        StudioReducer.reduce(&s, .addCut(EditTimeRange(start: 2, end: 3))) // outside → empty, ignored
        #expect(s == before)
    }

    @Test func sectionEditsAreClamped() {
        var s = Self.state()
        StudioReducer.reduce(&s, .setCursorScale(9))
        #expect(s.project.cursor.scale == 3)
        StudioReducer.reduce(&s, .setCursorSmoothing(-1))
        #expect(s.project.cursor.smoothing == 0)
        StudioReducer.reduce(&s, .setPadding(-10))
        #expect(s.project.canvas.padding == 0)
        StudioReducer.reduce(&s, .setAspectRatio(.square))
        #expect(s.project.canvas.aspectRatio == .square)
        StudioReducer.reduce(&s, .setBackgroundFill(.transparent))
        #expect(s.project.canvas.background.fill == .transparent)
        StudioReducer.reduce(&s, .setMotionBlur(StudioMotionBlur(enabled: false, intensity: 7)))
        #expect(s.project.motionBlur == StudioMotionBlur(enabled: false, intensity: 1))
        StudioReducer.reduce(&s, .setAudio(VideoEditAudio(muted: true, volume: 5)))
        #expect(s.project.audio.muted && s.project.audio.volume == 2)
        StudioReducer.reduce(&s, .setCamera(StudioCameraSettings(corner: .topLeft, mirrored: true)))
        #expect(s.project.camera.corner == .topLeft && s.project.camera.mirrored)
    }

    @Test func zoomSegments() {
        var s = Self.state()
        let auto1 = ZoomSegment(start: 0.05, end: 0.15)
        let auto2 = ZoomSegment(start: 0.75, end: 0.95)
        StudioReducer.reduce(&s, .replaceAutoZoomSegments([auto1, auto2]))
        #expect(s.project.zoom.segments.map(\.start) == [0.05, 0.2, 0.75]) // sorted, manual fixture kept
        #expect(s.project.zoom.segments.filter(\.isManual).map(\.id) == [V1StudioFixture.segmentID])

        // Editing an auto segment makes it manual; re-planning keeps it.
        var edited = auto2
        edited.scale = 3
        StudioReducer.reduce(&s, .updateZoomSegment(edited))
        StudioReducer.reduce(&s, .replaceAutoZoomSegments([]))
        #expect(Set(s.project.zoom.segments.map(\.id)) == [V1StudioFixture.segmentID, auto2.id])
        #expect(s.project.zoom.segments.first { $0.id == auto2.id }?.scale == 3)

        let added = ZoomSegment(start: 0.3, end: 0.35)
        StudioReducer.reduce(&s, .addZoomSegment(added))
        #expect(s.selectedZoomSegment == added.id)
        #expect(s.selectedSegment?.isManual == true)
        StudioReducer.reduce(&s, .removeZoomSegment(added.id))
        #expect(s.selectedZoomSegment == nil)
        StudioReducer.reduce(&s, .selectZoomSegment(UUID())) // unknown → nil
        #expect(s.selectedZoomSegment == nil)
    }
}

@MainActor
@Suite("StudioStore")
struct StudioStoreTests {
    @Test func undoRedo() {
        let original = V1StudioFixture.project()
        let store = StudioStore(project: original)
        #expect(!store.canUndo && !store.hasUnsavedChanges)

        store.apply(.setAspectRatio(.nineSixteen))
        store.apply(.setCursorScale(2.5))
        #expect(store.undoDepth == 2)
        #expect(store.undoActionName == "Cursor")
        #expect(store.hasUnsavedChanges)

        store.undo()
        #expect(store.project.cursor.scale == 2)
        #expect(store.redoActionName == "Cursor")
        store.undo()
        #expect(store.project == original)
        #expect(!store.canUndo && store.canRedo)
        store.redo()
        #expect(store.project.canvas.aspectRatio == .nineSixteen)

        // A new change clears redo.
        store.apply(.setAutoZoom(false))
        #expect(!store.canRedo)

        // No-op changes and selection don't create steps.
        let depth = store.undoDepth
        store.apply(.setAutoZoom(false))
        store.apply(.selectZoomSegment(V1StudioFixture.segmentID))
        #expect(store.undoDepth == depth)
        #expect(store.selectedZoomSegment == V1StudioFixture.segmentID)

        store.markSaved()
        #expect(!store.hasUnsavedChanges)
    }

    @Test func interactionsCoalesce() {
        let store = StudioStore(project: V1StudioFixture.project())
        store.beginInteraction("Padding")
        for value in stride(from: 32.0, through: 80, by: 8) {
            store.apply(.setPadding(value))
        }
        #expect(store.canUndo && store.undoActionName == "Padding" && store.undoDepth == 0)
        store.endInteraction()
        #expect(store.undoDepth == 1)
        store.undo()
        #expect(store.project.canvas.padding == 32)

        store.beginInteraction("Smoothing")
        store.apply(.setCursorSmoothing(0.9))
        store.cancelInteraction()
        #expect(store.project.cursor.smoothing == 0.5)
        #expect(store.undoDepth == 0)
    }

    @Test func undoRestoresSelectionAndLimit() {
        let store = StudioStore(project: V1StudioFixture.project(), undoLimit: 2)
        let seg = ZoomSegment(start: 0.3, end: 0.4)
        store.apply(.addZoomSegment(seg))
        store.apply(.removeZoomSegment(seg.id))
        #expect(store.selectedZoomSegment == nil)
        store.undo()
        #expect(store.selectedZoomSegment == seg.id)

        store.apply(.setClickEffect(false))
        store.apply(.setHideCursorWhenIdle(false))
        store.apply(.setCursorVisible(false))
        #expect(store.undoDepth == 2)

        store.replaceProject(V1StudioFixture.project())
        #expect(!store.canUndo && !store.canRedo && !store.hasUnsavedChanges)
    }
}
