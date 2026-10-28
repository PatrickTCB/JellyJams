#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import JellyJams

/// Drags tiles along a ``ReorderableHomeItemRow`` the way UIKit would: the
/// row is hosted in a window, and the hosting view's own drag and drop
/// interaction delegates are called with stand-in sessions. No touches are
/// synthesised.
///
/// Each tile's body opens with an `if`, as ``HomeItemTile``'s and the
/// Pinned row's tiles do. SwiftUI crashes as such a tile lifts
/// ("Unexpected identifier type") unless the row makes every tile a single
/// view. And a drop must reach `move`: with a `dropDestination` on the
/// `ForEach`, the row had no drop target at all, so every dropped tile
/// sprang back.
@MainActor
final class ReorderableHomeItemRowTests: XCTestCase {
    private let tiles = ["alpha", "bravo", "charlie"].map(Tile.init)
    private let frames = TileFrames()
    private var moves: [Move] = []
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    func testATileLifts() async throws {
        try await showRow()
        let (_, session) = try lift("bravo")
        XCTAssertEqual(session.dragItems.count, 1)
    }

    func testDroppingATileOnAnotherMovesItBeforeThatTile() async throws {
        try await showRow()
        let alpha = try frame(of: "alpha")
        try await drag("bravo", to: CGPoint(x: alpha.minX + alpha.width / 4, y: alpha.midY))
        XCTAssertEqual(moves, [Move(id: "bravo", index: 0)])
    }

    func testDroppingATilePastTheLastMovesItToTheEnd() async throws {
        try await showRow()
        let charlie = try frame(of: "charlie")
        try await drag("alpha", to: CGPoint(x: charlie.minX + charlie.width * 3 / 4, y: charlie.midY))
        XCTAssertEqual(moves, [Move(id: "alpha", index: tiles.count)])
    }

    /// Hosts the row in a window over the test host's own, and waits until
    /// SwiftUI has laid its tiles out.
    private func showRow() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "The test host has no window scene"
        )
        let frames = frames
        let row = ReorderableHomeItemRow(items: tiles, move: { [weak self] tile, index in
            self?.moves.append(Move(id: tile.id, index: index))
        }) { tile in
            ConditionalTile(tile: tile, frames: frames)
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: row)
        window.makeKeyAndVisible()
        self.window = window
        let deadline = Date.now + 5
        while frames.frames.count < tiles.count, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func frame(of id: String) throws -> CGRect {
        try XCTUnwrap(frames.frames[id], "\(id) was never laid out")
    }

    /// Lifts the tile from its centre, as a long-press would: UIKit asks
    /// the hosting view's drag interaction for the items to drag.
    private func lift(_ id: String) throws -> (UIDragInteraction, StandInDragSession) {
        let window = try XCTUnwrap(window)
        let interaction = try XCTUnwrap(
            interactions(of: UIDragInteraction.self, in: window).first,
            "Nothing in the row can be dragged"
        )
        let tile = try frame(of: id)
        let session = StandInDragSession(window: window, point: CGPoint(x: tile.midX, y: tile.midY))
        session.dragItems = interaction.delegate?.dragInteraction(interaction, itemsForBeginning: session) ?? []
        return (interaction, session)
    }

    /// Lifts the tile, carries it to `point` and drops it there.
    private func drag(_ id: String, to point: CGPoint) async throws {
        let window = try XCTUnwrap(window)
        let (dragInteraction, dragSession) = try lift(id)
        XCTAssertEqual(dragSession.dragItems.count, 1, "\(id) did not lift")
        let dropInteraction = try XCTUnwrap(
            interactions(of: UIDropInteraction.self, in: window).first,
            "Nothing in the row accepts a drop, so a dropped tile springs back"
        )
        let drag = try XCTUnwrap(dragInteraction.delegate)
        let drop = try XCTUnwrap(dropInteraction.delegate)
        let dropSession = StandInDropSession(dragSession: dragSession)

        drag.dragInteraction?(dragInteraction, sessionWillBegin: dragSession)
        drop.dropInteraction?(dropInteraction, sessionDidEnter: dropSession)
        dragSession.point = point
        drag.dragInteraction?(dragInteraction, sessionDidMove: dragSession)
        _ = drop.dropInteraction?(dropInteraction, sessionDidUpdate: dropSession)
        // The other tiles make way over a few frames, as under a finger.
        try await Task.sleep(for: .milliseconds(100))
        let operation = drop.dropInteraction?(dropInteraction, sessionDidUpdate: dropSession).operation
        XCTAssertEqual(operation, .move, "The row did not offer to move \(id) there")
        drop.dropInteraction?(dropInteraction, performDrop: dropSession)
        drop.dropInteraction?(dropInteraction, concludeDrop: dropSession)
        drop.dropInteraction?(dropInteraction, sessionDidEnd: dropSession)
        drag.dragInteraction?(dragInteraction, session: dragSession, willEndWith: .move)
        drag.dragInteraction?(dragInteraction, session: dragSession, didEndWith: .move)
        let deadline = Date.now + 2
        while moves.isEmpty, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func interactions<Interaction: UIInteraction>(
        of type: Interaction.Type,
        in view: UIView
    ) -> [Interaction] {
        view.interactions.compactMap { $0 as? Interaction }
            + view.subviews.flatMap { interactions(of: type, in: $0) }
    }
}

private struct Tile: Identifiable {
    let id: String
}

private struct Move: Equatable {
    let id: String
    let index: Int
}

/// Where SwiftUI laid each tile out, in the window's coordinates.
private final class TileFrames {
    var frames: [String: CGRect] = [:]
}

/// A tile whose body opens with a conditional, like ``HomeItemTile``'s.
private struct ConditionalTile: View {
    let tile: Tile
    let frames: TileFrames

    var body: some View {
        if tile.id == "alpha" {
            square(.red)
        } else {
            square(.blue)
        }
    }

    private func square(_ color: Color) -> some View {
        color
            .frame(width: 80, height: 80)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                frames.frames[tile.id] = frame
            }
    }
}

/// A drag in flight, standing in for UIKit's own session: the dragged items,
/// and where the finger is in the window.
@MainActor
private final class StandInDragSession: NSObject, UIDragSession {
    private let window: UIWindow
    var point: CGPoint
    var dragItems: [UIDragItem] = []
    var localContext: Any?

    init(window: UIWindow, point: CGPoint) {
        self.window = window
        self.point = point
    }

    var items: [UIDragItem] { dragItems }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { false }

    func location(in view: UIView) -> CGPoint {
        window.convert(point, to: view)
    }

    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
        dragItems.contains { item in
            typeIdentifiers.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) }
        }
    }

    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
        dragItems.contains { $0.itemProvider.canLoadObject(ofClass: aClass) }
    }
}

/// The same drag as the hosting view's drop interaction sees it.
@MainActor
private final class StandInDropSession: NSObject, UIDropSession {
    private let dragSession: StandInDragSession
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none
    let progress = Progress(totalUnitCount: 1)

    init(dragSession: StandInDragSession) {
        self.dragSession = dragSession
    }

    var localDragSession: (any UIDragSession)? { dragSession }
    var items: [UIDragItem] { dragSession.items }
    var allowsMoveOperation: Bool { dragSession.allowsMoveOperation }
    var isRestrictedToDraggingApplication: Bool { dragSession.isRestrictedToDraggingApplication }

    func location(in view: UIView) -> CGPoint {
        dragSession.location(in: view)
    }

    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
        dragSession.hasItemsConforming(toTypeIdentifiers: typeIdentifiers)
    }

    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
        dragSession.canLoadObjects(ofClass: aClass)
    }

    func loadObjects(
        ofClass aClass: any NSItemProviderReading.Type,
        completion: @escaping ([any NSItemProviderReading]) -> Void
    ) -> Progress {
        // A reorder never leaves the app, so nothing is loaded.
        progress
    }
}
#endif
