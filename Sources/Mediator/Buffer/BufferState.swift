//
//  Copyright © 2023 Mickaël Menu
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import Nvim
import Toolkit

/// State machine handling the state of a single buffer synchronized between the
/// UI and Nvim.
///
/// It is owned and executed by a `BufferMediator` which binds to the events of
/// the actual Nvim and UI buffers.
struct BufferState: Equatable {
    /// Indicates which buffer is the current source of truth for the content.
    private(set) var token: EditionToken

    /// State of the Nvim buffer.
    private(set) var nvim: NvimState

    /// State of the UI buffer.
    private(set) var ui: UIState

    init(
        token: EditionToken = .free,
        nvim: NvimState = NvimState(),
        ui: UIState = UIState()
    ) {
        self.token = token
        self.nvim = nvim
        self.ui = ui
    }

    /// The edition token indicates which buffer is the current source of truth
    /// for the content.
    ///
    /// While there are two actual live buffers for any buffer (Nvim and UI),
    /// there is no natural "source of truth" for the buffer content. Changes
    /// mostly come from Nvim, but in some cases we want to synchronize changes
    /// from the UI back to Nvim:
    /// * Auto-completion of symbols and snippets.
    /// * Paste using macOS clipboard through Cmd-V or "Paste" menu.
    /// * Undo/redo using the UI instead of u and ^R.
    ///
    /// To address this, `BufferState` uses a shared "edition token" whose
    /// owner temporarily becomes the source of truth.
    ///
    /// The edition token is automatically reset (released) after a short
    /// timeout without any editing events.
    enum EditionToken: Equatable {
        /// UI and Nvim are idle.
        case free

        /// One buffer acquired the token and became the source of truth for
        /// the content.
        case acquired(owner: Host)

        /// The main buffer released the token and is now synchronizing the full
        /// content with the subalternate buffer.
        ///
        /// The token will revert to `free` when receiving the next token
        /// timeout.
        case synchronizing
    }

    /// Identifiers the owner of a live buffer.
    enum Host: String, Equatable {
        case nvim
        case ui
    }

    /// Represents the current state of the Nvim buffer.
    struct NvimState: Equatable {
        /// Current cursor position and mode.
        var cursor: Cursor = .init(position: .init(), mode: .normal)

        /// Buffer content lines.
        var lines: [String] = []

        /// Converts the current cursor position as a selection range to
        /// represent the cursor in the UI buffer.
        func uiSelection() -> BufferSelection {
            switch cursor.mode {
            case .insert, .replace:
                return BufferSelection(start: cursor.position, end: cursor.position)
            default:
                let end = BufferPosition(line: cursor.position.line, column: cursor.position.column + 1)
                return BufferSelection(start: cursor.position, end: end)
            }
        }
    }

    /// Represents the current state of the UI buffer, accessed through the
    /// accessibility APIs (AX).
    struct UIState: Equatable {
        /// Current text selection in the buffer view.
        var selection: BufferSelection = .init()

        /// Buffer content lines.
        var lines: [String] = []
    }

    /// Events handled by the state machine.
    enum Event: Equatable {
        /// The edition token timed out and needs to be reset.
        case tokenDidTimeout

        /// The user requested to resynchronize the buffers using the given
        /// `source` host for the source of truth of the content.
        case userDidRequestRefresh(source: Host)

        /// The Nvim buffer changed and sent a `BufLinesEvent`.
        case nvimBufferDidChange(lines: [String], event: BufLinesEvent)

        /// The Nvim cursor moved or changed its mode.
        case nvimCursorDidChange(Cursor)

        /// The UI buffer regained focus.
        ///
        /// The current `lines` and `selection` are given in case they were
        /// changed by a third party.
        case uiDidFocus(lines: [String], selection: BufferSelection)

        /// The UI buffer changed with the given new `lines`.
        case uiBufferDidChange(lines: [String])

        /// The UI selection changed.
        case uiSelectionDidChange(BufferSelection)

        /// An error occurred.
        case didFail(EquatableError)
    }

    /// Actions produced by the state machine when receiving an event. They
    /// are executed by the `BufferMediator`.
    enum Action: Equatable {
        /// Update the content of the Nvim buffer with the new `lines` and
        /// cursor position.
        ///
        /// The `diff` contains the changes from the current Nvim `lines`.
        case updateNvim(lines: [String], diff: CollectionDifference<String>, cursorPosition: BufferPosition)

        /// Update the position of the Nvim cursor.
        case updateNvimCursor(BufferPosition)

        /// Update the content of the UI buffer with the new `lines` and text
        /// `selection`.
        ///
        /// The `diff` contains the changes from the current UI `lines`.
        case updateUI(lines: [String], diff: CollectionDifference<String>, selection: BufferSelection)

        /// Update a portion of the UI buffer using the given `BufLinesEvent`
        /// from Nvim.
        case updateUIPartialLines(event: BufLinesEvent)

        /// Update the current selection of the UI buffer.
        case updateUISelection(BufferSelection)

        /// Start a new timeout for the edition token. Any on-going timeout
        /// should be cancelled.
        case startTokenTimeout

        /// Emit a bell sound to the user.
        case bell

        /// Present the given error to the user.
        case alert(EquatableError)
    }

    mutating func on(_ event: Event, logger: Logger? = nil) -> [Action] {
        let oldState = self
        var actions: [Action] = []

        switch event {
        case .tokenDidTimeout:
            switch token {
            case .free:
                break
            case .synchronizing:
                token = .free
            case let .acquired(owner: owner):
                synchronize(source: owner)
            }

        case let .userDidRequestRefresh(source: source):
            switch token {
            case .synchronizing, .acquired:
                logger?.w("Token busy, cannot refresh")
                perform(.bell)
            case .free:
                synchronize(source: source)
            }

        case let .nvimBufferDidChange(lines: lines, event: event):
            nvim.lines = lines

            if tryEdition(from: .nvim) {
                perform(.updateUIPartialLines(event: event))
                perform(.updateUISelection(nvim.uiSelection()))
            }

        case let .nvimCursorDidChange(cursor):
            nvim.cursor = cursor

            if tryEdition(from: .nvim) {
                perform(.updateUISelection(nvim.uiSelection()))
            }

        case let .uiDidFocus(lines: lines, selection: selection):
            ui.lines = lines
            ui.selection = selection

            if tryEdition(from: .ui) {
                synchronizeNvim()
            }

        case let .uiBufferDidChange(lines: lines):
            ui.lines = lines

            if tryEdition(from: .ui) {
                synchronizeNvim()
            }

        case let .uiSelectionDidChange(selection):
            ui.selection = selection

            if tryEdition(from: .ui), nvim.cursor.position != selection.start {
                perform(.updateNvimCursor(selection.start))
            }

        case let .didFail(error):
            perform(.alert(error))
        }

        // Syntactic sugar.
        func perform(_ action: Action) {
            actions.append(action)
        }

        /// Try to acquire the edition token for the given `host` to modify the
        /// shared virtual buffer.
        func tryEdition(from host: Host) -> Bool {
            switch token {
            case .free, .acquired(owner: host):
                token = .acquired(owner: host)
                perform(.startTokenTimeout)
                return true
            default:
                return false
            }
        }

        /// Synchronizes the whole buffer using the given `source` of truth.
        func synchronize(source: Host) {
            // Some apps (like Xcode) systematically add an empty line at
            // the end of a document. To make sure the comparison won't
            // fail in this case, we add an empty line in the Nvim buffer
            // as well.
            var nvimLines = nvim.lines
            if ui.lines.last == "", nvimLines.last != "" {
                nvimLines.append("")
            }
            guard ui.lines != nvimLines else {
                token = .free
                return
            }

            switch source {
            case .nvim:
                synchronizeUI()
            case .ui:
                synchronizeNvim()
            }

            token = .synchronizing
            perform(.startTokenTimeout)
        }

        func synchronizeUI() {
            perform(.updateUI(
                lines: nvim.lines,
                diff: nvim.lines.difference(from: ui.lines),
                selection: nvim.uiSelection()
            ))
        }

        func synchronizeNvim() {
            perform(.updateNvim(
                lines: ui.lines,
                diff: ui.lines.difference(from: nvim.lines),
                cursorPosition: ui.selection.start
            ))
        }

        let newState = self
        logger?.t("on \(event.name)", [
            "event": event,
            "oldState": oldState,
            "newState": newState,
            "actions": actions,
        ])
        return actions
    }
}

// MARK: - Logging

extension BufferState.EditionToken: LogValueConvertible {
    var logValue: LogValue {
        switch self {
        case .free:
            return .string("free")
        case let .acquired(owner: owner):
            return .string("acquired by \(owner.rawValue)")
        case .synchronizing:
            return .string("synchronizing")
        }
    }
}

extension BufferState: LogPayloadConvertible {
    func logPayload() -> [LogKey: LogValueConvertible] {
        ["token": token, "nvim": nvim, "ui": ui]
    }
}

extension BufferState.NvimState: LogPayloadConvertible {
    func logPayload() -> [LogKey: LogValueConvertible] {
        ["lines": lines, "cursor": cursor]
    }
}

extension BufferState.UIState: LogPayloadConvertible {
    func logPayload() -> [LogKey: LogValueConvertible] {
        ["lines": lines, "selection": selection]
    }
}

extension BufferState.Event: LogPayloadConvertible {
    var name: String {
        switch self {
        case .tokenDidTimeout:
            return "tokenDidTimeout"
        case .userDidRequestRefresh:
            return "userDidRequestRefresh"
        case .nvimBufferDidChange:
            return "nvimBufferDidChange"
        case .nvimCursorDidChange:
            return "nvimCursorDidChange"
        case .uiDidFocus:
            return "uiDidFocus"
        case .uiBufferDidChange:
            return "uiBufferDidChange"
        case .uiSelectionDidChange:
            return "uiSelectionDidChange"
        case .didFail:
            return "didFail"
        }
    }

    func logPayload() -> [LogKey: LogValueConvertible] {
        switch self {
        case .tokenDidTimeout:
            return [.name: name]
        case let .userDidRequestRefresh(source: source):
            return [.name: name, "source": source.rawValue]
        case let .nvimBufferDidChange(lines: newLines, event: event):
            return [.name: name, "newLines": newLines, "event": event]
        case let .nvimCursorDidChange(cursor):
            return [.name: name, "cursor": cursor]
        case let .uiDidFocus(lines: lines, selection: selection):
            return [.name: name, "lines": lines, "selection": selection]
        case let .uiBufferDidChange(lines: lines):
            return [.name: name, "lines": lines]
        case let .uiSelectionDidChange(selection):
            return [.name: name, "selection": selection]
        case let .didFail(error):
            return [.name: name, "error": error]
        }
    }
}

extension BufferState.Action: LogPayloadConvertible {
    func logPayload() -> [LogKey: LogValueConvertible] {
        switch self {
        case let .updateNvim(lines: lines, diff: diff, cursorPosition: cursorPosition):
            return [.name: "updateNvim", "lines": lines, "diff": diff, "cursorPosition": cursorPosition]
        case let .updateNvimCursor(cursor):
            return [.name: "updateNvimCursor", "cursor": cursor]
        case let .updateUI(lines: lines, diff: diff, selection: selection):
            return [.name: "updateUI", "lines": lines, "diff": diff, "selection": selection]
        case let .updateUIPartialLines(event: event):
            return [.name: "updateUIPartialLines", "event": event]
        case let .updateUISelection(selection):
            return [.name: "updateUISelection", "selection": selection]
        case .startTokenTimeout:
            return [.name: "startTokenTimeout"]
        case .bell:
            return [.name: "bell"]
        case let .alert(error):
            return [.name: "alert", "error": error]
        }
    }
}

private extension LogKey {
    static var name: LogKey { "name" }
}