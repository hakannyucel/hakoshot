import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("EditorReducer")
struct EditorReducerTests {
    private func state(_ annotations: [Annotation] = []) -> EditorState {
        var doc = AnnotationFixtures.emptyDocument()
        doc.annotations = annotations
        return EditorState(document: doc)
    }

    @Test func addAppendsOnTopAndSelects() {
        let a = AnnotationFixtures.rect(0, 0, 10, 10)
        let b = AnnotationFixtures.rect(5, 5, 10, 10)
        var s = EditorReducer.reduce(state([a]), .add(b))
        #expect(s.document.annotations.map(\.id) == [a.id, b.id])
        #expect(s.selection == [b.id])
        // Adding the same ID twice is a no-op.
        s = EditorReducer.reduce(s, .add(b))
        #expect(s.document.annotations.count == 2)
        let unselected = EditorReducer.reduce(state(), .add(a, select: false))
        #expect(unselected.selection.isEmpty)
    }

    @Test func updateReplacesByID() {
        var a = AnnotationFixtures.rect(0, 0, 10, 10)
        let s0 = state([a])
        a.style.color = .annotationGreen
        let s = EditorReducer.reduce(s0, .update(a))
        #expect(s.document.annotations.first?.style.color == .annotationGreen)
        // Unknown ID: nothing happens.
        let other = AnnotationFixtures.rect(1, 1, 1, 1)
        #expect(EditorReducer.reduce(s, .update(other)) == s)
    }

    @Test func deleteRemovesAndPrunesSelection() {
        let a = AnnotationFixtures.rect(0, 0, 10, 10)
        let b = AnnotationFixtures.rect(5, 5, 10, 10)
        var s = state([a, b])
        s.selection = [a.id, b.id]
        s = EditorReducer.reduce(s, .delete([a.id]))
        #expect(s.document.annotations.map(\.id) == [b.id])
        #expect(s.selection == [b.id])
        s = EditorReducer.reduce(s, .deleteSelection)
        #expect(s.document.annotations.isEmpty)
        #expect(s.selection.isEmpty)
    }

    @Test func moveTranslatesEveryGeometryKind() {
        let all = AnnotationFixtures.everyKind()
        let s = EditorReducer.reduce(state(all), .move(Set(all.map(\.id)), by: CGVector(dx: 10, dy: -5)))
        for (before, after) in zip(all, s.document.annotations) {
            let b = before.bounds, a = after.bounds
            #expect(abs(a.minX - (b.minX + 10)) < 1e-9, "\(before.kind.tag)")
            #expect(abs(a.minY - (b.minY - 5)) < 1e-9, "\(before.kind.tag)")
            #expect(abs(a.width - b.width) < 1e-9)
        }
    }

    @Test func resizeMovesHandle() {
        let a = AnnotationFixtures.rect(0, 0, 100, 50)
        let s = EditorReducer.reduce(state([a]), .resize(a.id, handle: .bottomRight, to: CGPoint(x: 200, y: 80)))
        #expect(s.document.annotations.first?.bounds == CGRect(x: 0, y: 0, width: 200, height: 80))
    }

    @Test func restyleAppliesPatchPerKind() {
        let rect = AnnotationFixtures.rect(0, 0, 10, 10)
        let counter = AnnotationFixtures.counter(1)
        let redaction = Annotation(kind: .redaction(RedactionShape(rect: CGRect(x: 0, y: 0, width: 50, height: 50),
                                                                   method: .pixelate, strength: 24, seed: 1)),
                                   style: AnnotationStyle())
        let patch = AnnotationPatch(color: .annotationBlue, strokeWidth: 16, fill: .some(nil),
                                    counterStyle: .filledSquare, redactionMethod: .smoothBlur)
        let s = EditorReducer.reduce(state([rect, counter, redaction]), .restyle([rect.id, counter.id, redaction.id], patch))
        let annotations = s.document.annotations
        #expect(annotations.allSatisfy { $0.style.color == .annotationBlue && $0.style.strokeWidth == 16 })
        #expect(annotations[1].counter?.counterStyle == .filledSquare)
        #expect(annotations[1].counter?.diameter == 80) // max(5·16, 24·2)
        guard case .redaction(let r) = annotations[2].kind else {
            Issue.record("expected redaction")
            return
        }
        #expect(r.method == .smoothBlur)
        #expect(r.strength == 40) // 20 pt × scale 2
    }

    @Test func reorderOperations() {
        let a = AnnotationFixtures.rect(0, 0, 1, 1)
        let b = AnnotationFixtures.rect(0, 0, 2, 2)
        let c = AnnotationFixtures.rect(0, 0, 3, 3)
        let d = AnnotationFixtures.rect(0, 0, 4, 4)
        let s = state([a, b, c, d])
        func order(_ op: ReorderOperation, _ ids: Set<UUID>) -> [UUID] {
            EditorReducer.reduce(s, .reorder(ids, op)).document.annotations.map(\.id)
        }
        #expect(order(.bringToFront, [a.id]) == [b.id, c.id, d.id, a.id])
        #expect(order(.sendToBack, [d.id]) == [d.id, a.id, b.id, c.id])
        #expect(order(.bringForward, [b.id]) == [a.id, c.id, b.id, d.id])
        #expect(order(.sendBackward, [c.id]) == [a.id, c.id, b.id, d.id])
        // Multiple selected keep their relative order.
        #expect(order(.bringToFront, [a.id, c.id]) == [b.id, d.id, a.id, c.id])
        #expect(order(.bringForward, [c.id, d.id]) == [a.id, b.id, c.id, d.id]) // already on top
        #expect(order(.sendBackward, [a.id]) == [a.id, b.id, c.id, d.id]) // already at bottom
    }

    @Test func duplicateOffsetsSelectsAndRenumbersCounters() {
        let rect = AnnotationFixtures.rect(0, 0, 10, 10)
        let counter = AnnotationFixtures.counter(4)
        let s = EditorReducer.reduce(state([rect, counter]), .duplicate([rect.id, counter.id], offset: CGVector(dx: 20, dy: 20)))
        #expect(s.document.annotations.count == 4)
        let copies = Array(s.document.annotations.suffix(2))
        #expect(Set(copies.map(\.id)) == s.selection)
        #expect(!s.selection.contains(rect.id))
        #expect(copies[0].bounds == CGRect(x: 20, y: 20, width: 10, height: 10))
        #expect(copies[1].counter?.number == 5)
    }

    @Test func counterNumberingAfterDeleteDoesNotRenumber() {
        let c1 = AnnotationFixtures.counter(1), c2 = AnnotationFixtures.counter(2), c3 = AnnotationFixtures.counter(3)
        var s = state([c1, c2, c3])
        s = EditorReducer.reduce(s, .delete([c2.id]))
        #expect(s.document.annotations.compactMap(\.counter?.number) == [1, 3])
        #expect(s.nextCounterNumber == 4)
        s = EditorReducer.reduce(s, .delete([c3.id]))
        #expect(s.nextCounterNumber == 2)
        s = EditorReducer.reduce(s, .delete([c1.id]))
        #expect(s.nextCounterNumber == s.toolSettings.counterStartNumber)
    }

    @Test func renumberCountersClosesGapsInNumericOrder() {
        let c5 = AnnotationFixtures.counter(5), c1 = AnnotationFixtures.counter(1), c3 = AnnotationFixtures.counter(3)
        let rect = AnnotationFixtures.rect(0, 0, 1, 1)
        let s = EditorReducer.reduce(state([c5, rect, c1, c3]), .renumberCounters(startingAt: 0))
        let numbers = s.document.annotations.map { $0.counter?.number }
        #expect(numbers == [2, nil, 0, 1])
        #expect(s.toolSettings.counterStartNumber == 0)
        #expect(s.nextCounterNumber == 3)
    }

    @Test func counterStartNumberZeroIsHonored() {
        var s = state()
        s.toolSettings.counterStartNumber = 0
        #expect(s.nextCounterNumber == 0)
    }

    @Test func selectionActionsIgnoreUnknownIDs() {
        let a = AnnotationFixtures.rect(0, 0, 1, 1)
        let b = AnnotationFixtures.rect(0, 0, 2, 2)
        var s = state([a, b])
        s = EditorReducer.reduce(s, .select([a.id, UUID()]))
        #expect(s.selection == [a.id])
        s = EditorReducer.reduce(s, .toggleSelection(b.id))
        #expect(s.selection == [a.id, b.id])
        s = EditorReducer.reduce(s, .toggleSelection(a.id))
        #expect(s.selection == [b.id])
        s = EditorReducer.reduce(s, .clearSelection)
        #expect(s.selection.isEmpty)
        s = EditorReducer.reduce(s, .selectAll)
        #expect(s.selection == [a.id, b.id])
        s = EditorReducer.reduce(s, .setTool(.rectangle))
        #expect(s.selection.isEmpty && s.tool == .rectangle)
    }

    @Test func cropIsClampedAndClearable() {
        var s = EditorReducer.reduce(state(), .setCrop(CGRect(x: -50, y: 100, width: 500, height: 5000)))
        #expect(s.document.crop == CGRect(x: 0, y: 100, width: 450, height: 1100))
        #expect(s.document.visibleRect == CGRect(x: 0, y: 100, width: 450, height: 1100))
        s = EditorReducer.reduce(s, .setCrop(CGRect(x: 5000, y: 5000, width: 10, height: 10)))
        #expect(s.document.crop == nil)
        s = EditorReducer.reduce(s, .setCrop(CGRect(x: 10, y: 10, width: 20, height: 20)))
        s = EditorReducer.reduce(s, .setCrop(nil))
        #expect(s.document.crop == nil)
    }
}

@Suite("EditorStore undo")
@MainActor
struct EditorStoreUndoTests {
    private func makeStore(undoLimit: Int = 200) -> EditorStore {
        EditorStore(document: AnnotationFixtures.emptyDocument(), undoLimit: undoLimit)
    }

    @Test func undoRedoOrder() {
        let store = makeStore()
        let a = AnnotationFixtures.rect(0, 0, 10, 10)
        let b = AnnotationFixtures.rect(20, 20, 10, 10)
        store.apply(.add(a))
        store.apply(.add(b))
        store.apply(.move([a.id], by: CGVector(dx: 5, dy: 0)))
        #expect(store.undoDepth == 3)
        #expect(store.undoActionName == "Move")

        store.undo()
        #expect(store.document.annotations.map(\.bounds.minX) == [0, 20])
        #expect(store.redoActionName == "Move")
        store.undo()
        #expect(store.document.annotations.map(\.id) == [a.id])
        #expect(store.selection == [a.id]) // selection restored from before "Add"
        store.undo()
        #expect(store.document.annotations.isEmpty)
        #expect(!store.canUndo)
        store.undo() // no-op
        #expect(store.canRedo)

        store.redo()
        store.redo()
        #expect(store.document.annotations.map(\.id) == [a.id, b.id])
        store.redo()
        #expect(store.document.annotations.first?.bounds.minX == 5)
        #expect(!store.canRedo)
    }

    @Test func newChangeClearsRedo() {
        let store = makeStore()
        store.apply(.add(AnnotationFixtures.rect(0, 0, 10, 10)))
        store.undo()
        #expect(store.canRedo)
        store.apply(.add(AnnotationFixtures.rect(1, 1, 10, 10)))
        #expect(!store.canRedo)
    }

    @Test func selectionAndToolChangesAreNotUndoSteps() {
        let store = makeStore()
        let a = AnnotationFixtures.rect(0, 0, 10, 10)
        store.apply(.add(a, select: false))
        store.apply(.select([a.id]))
        store.apply(.setTool(.pencil))
        var settings = store.toolSettings
        settings.color = .annotationGreen
        store.apply(.setToolSettings(settings))
        #expect(store.undoDepth == 1)
        #expect(store.toolSettings.color == .annotationGreen)
    }

    @Test func noOpActionsAreNotRecorded() {
        let store = makeStore()
        store.apply(.delete([UUID()]))
        store.apply(.move([UUID()], by: CGVector(dx: 1, dy: 1)))
        #expect(!store.canUndo)
    }

    @Test func dragIsCoalescedIntoOneStep() {
        let store = makeStore()
        let a = AnnotationFixtures.rect(0, 0, 10, 10)
        store.apply(.add(a))
        store.beginInteraction("Move")
        #expect(store.isInteracting)
        for _ in 0..<30 {
            store.apply(.move([a.id], by: CGVector(dx: 1, dy: 2)))
        }
        #expect(store.undoDepth == 1) // nothing recorded mid-drag
        store.endInteraction()
        #expect(store.undoDepth == 2)
        #expect(store.document.annotations.first?.bounds.origin == CGPoint(x: 30, y: 60))

        store.undo()
        #expect(store.document.annotations.first?.bounds.origin == .zero)
        store.redo()
        #expect(store.document.annotations.first?.bounds.origin == CGPoint(x: 30, y: 60))
    }

    @Test func creationDragIsOneStep() {
        let store = makeStore()
        let start = CGPoint(x: 100, y: 100)
        store.beginInteraction("Add Rectangle")
        let created = AnnotationFactory.begin(tool: .rectangle, at: start, settings: store.toolSettings,
                                              scale: store.document.canvas.scale,
                                              nextCounterNumber: store.nextCounterNumber)
        guard var current = created else {
            Issue.record("factory returned nil")
            return
        }
        store.apply(.add(current))
        for x in stride(from: 110.0, through: 300, by: 10) {
            current = AnnotationFactory.update(current, anchor: start, to: CGPoint(x: x, y: x), constrained: false)
            store.apply(.update(current))
        }
        let finished = AnnotationFactory.finish(current)
        #expect(finished != nil)
        store.endInteraction()
        #expect(store.undoDepth == 1)
        #expect(store.undoActionName == "Add Rectangle")
        store.undo()
        #expect(store.document.annotations.isEmpty)
    }

    @Test func interactionWithoutChangesRecordsNothing() {
        let store = makeStore()
        store.beginInteraction("Move")
        store.apply(.select([]))
        store.endInteraction()
        #expect(!store.canUndo)
    }

    @Test func cancelInteractionRestores() {
        let store = makeStore()
        let a = AnnotationFixtures.rect(0, 0, 10, 10)
        store.apply(.add(a))
        store.beginInteraction("Resize")
        store.apply(.resize(a.id, handle: .right, to: CGPoint(x: 500, y: 5)))
        #expect(store.canUndo)
        store.cancelInteraction()
        #expect(!store.isInteracting)
        #expect(store.document.annotations.first?.bounds.width == 10)
        #expect(store.undoDepth == 1)
    }

    @Test func undoDuringInteractionCommitsItFirst() {
        let store = makeStore()
        let a = AnnotationFixtures.rect(0, 0, 10, 10)
        store.apply(.add(a))
        store.beginInteraction("Move")
        store.apply(.move([a.id], by: CGVector(dx: 50, dy: 0)))
        #expect(store.undoActionName == "Move")
        store.undo()
        #expect(!store.isInteracting)
        #expect(store.document.annotations.first?.bounds.minX == 0)
        #expect(store.undoDepth == 1)
    }

    @Test func undoLimitDropsOldest() {
        let store = makeStore(undoLimit: 3)
        for i in 0..<5 {
            store.apply(.add(AnnotationFixtures.rect(Double(i), 0, 1, 1)))
        }
        #expect(store.undoDepth == 3)
        store.undo(); store.undo(); store.undo()
        #expect(store.document.annotations.count == 2)
        #expect(!store.canUndo)
    }

    @Test func defaultUndoLimitIs200() {
        #expect(makeStore().undoLimit == 200)
        #expect(EditorStore(document: AnnotationFixtures.emptyDocument()).undoLimit == 200)
    }

    @Test func unsavedChangesTracking() {
        let store = makeStore()
        #expect(!store.hasUnsavedChanges)
        store.apply(.add(AnnotationFixtures.rect(0, 0, 1, 1)))
        #expect(store.hasUnsavedChanges)
        store.markSaved()
        #expect(!store.hasUnsavedChanges)
        store.undo()
        #expect(store.hasUnsavedChanges)
    }

    @Test func replaceDocumentClearsHistory() {
        let store = makeStore()
        store.apply(.add(AnnotationFixtures.rect(0, 0, 1, 1)))
        store.replaceDocument(AnnotationFixtures.fullDocument())
        #expect(!store.canUndo && !store.canRedo)
        #expect(!store.hasUnsavedChanges)
        #expect(store.selection.isEmpty)
    }

    @Test func cropIsUndoable() {
        let store = makeStore()
        store.apply(.setCrop(CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(store.undoActionName == "Crop")
        store.undo()
        #expect(store.document.crop == nil)
    }
}
