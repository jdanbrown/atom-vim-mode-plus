const {Range} = require("atom")
const Base = require("./base")

const {
  moveCursorRight,
  isLinewiseRange,
  setBufferRow,
  sortRanges,
  findRangeContainsPoint,
  isSingleLineRange,
  isLeadingWhiteSpaceRange,
  humanizeBufferRange,
  getFoldInfoByKind,
  limitNumber,
  getFoldRowRangesContainedByFoldStartsAtRow,
  getList,
} = require("./utils")

class MiscCommand extends Base {
  static initClass(...args) {
    this.operationKind = "misc-command"
    super.initClass(...args)
  }
  constructor(...args) {
    super(...args)
    this.initialize()
  }
}
MiscCommand.initClass(false)

class Mark extends MiscCommand {
  initialize() {
    this.requireInput = true
    this.readChar()
  }

  execute() {
    this.vimState.mark.set(this.input, this.editor.getCursorBufferPosition())
    this.activateMode("normal")
  }
}
Mark.initClass()

class ReverseSelections extends MiscCommand {
  execute() {
    this.swrap.setReversedState(this.editor, !this.editor.getLastSelection().isReversed())
    if (this.isMode("visual", "blockwise")) {
      this.getLastBlockwiseSelection().autoscroll()
    }
  }
}
ReverseSelections.initClass()

class BlockwiseOtherEnd extends ReverseSelections {
  execute() {
    for (const blockwiseSelection of this.getBlockwiseSelections()) {
      blockwiseSelection.reverse()
    }
    super.execute()
  }
}
BlockwiseOtherEnd.initClass()

class Undo extends MiscCommand {
  setCursorPosition({newRanges, oldRanges, strategy}) {
    const lastCursor = this.editor.getLastCursor() // This is restored cursor

    const changedRange =
      strategy === "smart"
        ? findRangeContainsPoint(newRanges, lastCursor.getBufferPosition())
        : sortRanges(newRanges.concat(oldRanges))[0]

    if (changedRange) {
      if (isLinewiseRange(changedRange)) setBufferRow(lastCursor, changedRange.start.row)
      else lastCursor.setBufferPosition(changedRange.start)
    }
  }

  mutateWithTrackChanges() {
    const newRanges = []
    const oldRanges = []

    // Collect changed range while mutating text-state by fn callback.
    const disposable = this.editor.getBuffer().onDidChange(({newRange, oldRange}) => {
      if (newRange.isEmpty()) {
        oldRanges.push(oldRange) // Remove only
      } else {
        newRanges.push(newRange)
      }
    })

    this.mutate()
    disposable.dispose()
    return {newRanges, oldRanges}
  }

  flashChanges({newRanges, oldRanges}) {
    const isMultipleSingleLineRanges = ranges => ranges.length > 1 && ranges.every(isSingleLineRange)

    if (newRanges.length > 0) {
      if (this.isMultipleAndAllRangeHaveSameColumnAndConsecutiveRows(newRanges)) return

      newRanges = newRanges.map(range => humanizeBufferRange(this.editor, range))
      newRanges = this.filterNonLeadingWhiteSpaceRange(newRanges)

      const type = isMultipleSingleLineRanges(newRanges) ? "undo-redo-multiple-changes" : "undo-redo"
      this.flash(newRanges, {type})
    } else {
      if (this.isMultipleAndAllRangeHaveSameColumnAndConsecutiveRows(oldRanges)) return

      if (isMultipleSingleLineRanges(oldRanges)) {
        oldRanges = this.filterNonLeadingWhiteSpaceRange(oldRanges)
        this.flash(oldRanges, {type: "undo-redo-multiple-delete"})
      }
    }
  }

  filterNonLeadingWhiteSpaceRange(ranges) {
    return ranges.filter(range => !isLeadingWhiteSpaceRange(this.editor, range))
  }

  // [TODO] Improve further by checking oldText, newText?
  // [Purpose of this function]
  // Suppress flash when undo/redoing toggle-comment while flashing undo/redo of occurrence operation.
  // This huristic approach never be perfect.
  // Ultimately cannnot distinguish occurrence operation.
  isMultipleAndAllRangeHaveSameColumnAndConsecutiveRows(ranges) {
    if (ranges.length <= 1) {
      return false
    }

    const {start: {column: startColumn}, end: {column: endColumn}} = ranges[0]
    let previousRow

    for (const range of ranges) {
      const {start, end} = range
      if (start.column !== startColumn || end.column !== endColumn) return false
      if (previousRow != null && previousRow + 1 !== start.row) return false
      previousRow = start.row
    }
    return true
  }

  flash(ranges, options) {
    if (options.timeout == null) options.timeout = 500
    this.onDidFinishOperation(() => this.vimState.flash(ranges, options))
  }

  execute() {
    const {newRanges, oldRanges} = this.mutateWithTrackChanges()

    for (const selection of this.editor.getSelections()) {
      selection.clear()
    }

    if (this.getConfig("setCursorToStartOfChangeOnUndoRedo")) {
      const strategy = this.getConfig("setCursorToStartOfChangeOnUndoRedoStrategy")
      this.setCursorPosition({newRanges, oldRanges, strategy})
      this.vimState.clearSelections()
    }

    if (this.getConfig("flashOnUndoRedo")) this.flashChanges({newRanges, oldRanges})
    this.activateMode("normal")
  }

  mutate() {
    this.editor.undo()
  }
}
Undo.initClass()

class Redo extends Undo {
  mutate() {
    this.editor.redo()
  }
}
Redo.initClass()

// zc
class FoldCurrentRow extends MiscCommand {
  execute() {
    for (const selection of this.editor.getSelections()) {
      this.editor.foldBufferRow(this.getCursorPositionForSelection(selection).row)
    }
  }
}
FoldCurrentRow.initClass()

// zo
class UnfoldCurrentRow extends MiscCommand {
  execute() {
    for (const selection of this.editor.getSelections()) {
      this.editor.unfoldBufferRow(this.getCursorPositionForSelection(selection).row)
    }
  }
}
UnfoldCurrentRow.initClass()

// za
class ToggleFold extends MiscCommand {
  execute() {
    this.editor.toggleFoldAtBufferRow(this.editor.getCursorBufferPosition().row)
  }
}
ToggleFold.initClass()

// Base of zC, zO, zA
class FoldCurrentRowRecursivelyBase extends MiscCommand {
  foldRecursively(row) {
    const rowRanges = getFoldRowRangesContainedByFoldStartsAtRow(this.editor, row)
    if (!rowRanges) return
    const startRows = rowRanges.map(rowRange => rowRange[0])
    for (const row of startRows.reverse()) {
      if (!this.editor.isFoldedAtBufferRow(row)) {
        this.editor.foldBufferRow(row)
      }
    }
  }

  unfoldRecursively(row) {
    const rowRanges = getFoldRowRangesContainedByFoldStartsAtRow(this.editor, row)
    if (!rowRanges) return
    const startRows = rowRanges.map(rowRange => rowRange[0])
    for (row of startRows) {
      if (this.editor.isFoldedAtBufferRow(row)) {
        this.editor.unfoldBufferRow(row)
      }
    }
  }

  foldRecursivelyForAllSelections() {
    for (const selection of this.editor.getSelectionsOrderedByBufferPosition().reverse()) {
      this.foldRecursively(this.getCursorPositionForSelection(selection).row)
    }
  }

  unfoldRecursivelyForAllSelections() {
    for (const selection of this.editor.getSelectionsOrderedByBufferPosition()) {
      this.unfoldRecursively(this.getCursorPositionForSelection(selection).row)
    }
  }
}
FoldCurrentRowRecursivelyBase.initClass(false)

// zC
class FoldCurrentRowRecursively extends FoldCurrentRowRecursivelyBase {
  execute() {
    this.foldRecursivelyForAllSelections()
  }
}
FoldCurrentRowRecursively.initClass()

// zO
class UnfoldCurrentRowRecursively extends FoldCurrentRowRecursivelyBase {
  execute() {
    this.unfoldRecursivelyForAllSelections()
  }
}
UnfoldCurrentRowRecursively.initClass()

// zA
class ToggleFoldRecursively extends FoldCurrentRowRecursivelyBase {
  execute() {
    const {row} = this.getCursorPositionForSelection(this.editor.getLastSelection())
    if (this.editor.isFoldedAtBufferRow(row)) {
      this.unfoldRecursivelyForAllSelections()
    } else {
      this.foldRecursivelyForAllSelections()
    }
  }
}
ToggleFoldRecursively.initClass()

// zR
class UnfoldAll extends MiscCommand {
  execute() {
    this.editor.unfoldAll()
  }
}
UnfoldAll.initClass()

// zM
class FoldAll extends MiscCommand {
  execute() {
    const {allFold} = getFoldInfoByKind(this.editor)
    if (!allFold) return

    this.editor.unfoldAll()
    for (const {indent, startRow, endRow} of allFold.rowRangesWithIndent) {
      if (indent <= this.getConfig("maxFoldableIndentLevel")) {
        this.editor.foldBufferRowRange(startRow, endRow)
      }
    }
  }
}
FoldAll.initClass()

// zr
class UnfoldNextIndentLevel extends MiscCommand {
  execute() {
    const {folded} = getFoldInfoByKind(this.editor)
    if (!folded) return
    const {minIndent, rowRangesWithIndent} = folded
    const count = limitNumber(this.getCount() - 1, {min: 0})
    const targetIndents = getList(minIndent, minIndent + count)
    for (const {indent, startRow} of rowRangesWithIndent) {
      if (targetIndents.includes(indent)) {
        this.editor.unfoldBufferRow(startRow)
      }
    }
  }
}
UnfoldNextIndentLevel.initClass()

// zm
class FoldNextIndentLevel extends MiscCommand {
  execute() {
    const {unfolded, allFold} = getFoldInfoByKind(this.editor)
    if (!unfolded) return
    // FIXME: Why I need unfoldAll()? Why can't I just fold non-folded-fold only?
    // Unless unfoldAll() here, @editor.unfoldAll() delete foldMarker but fail
    // to render unfolded rows correctly.
    // I believe this is bug of text-buffer's markerLayer which assume folds are
    // created **in-order** from top-row to bottom-row.
    this.editor.unfoldAll()

    const maxFoldable = this.getConfig("maxFoldableIndentLevel")
    let fromLevel = Math.min(unfolded.maxIndent, maxFoldable)
    const count = limitNumber(this.getCount() - 1, {min: 0})
    fromLevel = limitNumber(fromLevel - count, {min: 0})
    const targetIndents = getList(fromLevel, maxFoldable)
    for (const {indent, startRow, endRow} of allFold.rowRangesWithIndent) {
      if (targetIndents.includes(indent)) {
        this.editor.foldBufferRowRange(startRow, endRow)
      }
    }
  }
}
FoldNextIndentLevel.initClass()

class ReplaceModeBackspace extends MiscCommand {
  static initClass(...args) {
    this.commandScope = "atom-text-editor.vim-mode-plus.insert-mode.replace"
    super.initClass(...args)
  }
  execute() {
    for (const selection of this.editor.getSelections()) {
      // char might be empty.
      const char = this.vimState.modeManager.getReplacedCharForSelection(selection)
      if (char != null) {
        selection.selectLeft()
        if (!selection.insertText(char).isEmpty()) selection.cursor.moveLeft()
      }
    }
  }
}
ReplaceModeBackspace.initClass()

class ScrollWithoutChangingCursorPosition extends MiscCommand {
  initialize() {
    this.scrolloff = 2 // atom default. Better to use editor.getVerticalScrollMargin()?
    this.cursorPixel = null
  }

  getFirstVisibleScreenRow() {
    return this.editorElement.getFirstVisibleScreenRow()
  }

  getLastVisibleScreenRow() {
    return this.editorElement.getLastVisibleScreenRow()
  }

  getLastScreenRow() {
    return this.editor.getLastScreenRow()
  }

  getCursorPixel() {
    const point = this.editor.getCursorScreenPosition()
    return this.editorElement.pixelPositionForScreenPosition(point)
  }
}
ScrollWithoutChangingCursorPosition.initClass(false)

// ctrl-e scroll lines downwards
class ScrollDown extends ScrollWithoutChangingCursorPosition {
  execute() {
    const count = this.getCount()
    const oldFirstRow = this.editor.getFirstVisibleScreenRow()
    this.editor.setFirstVisibleScreenRow(oldFirstRow + count)
    const newFirstRow = this.editor.getFirstVisibleScreenRow()

    const offset = 2
    const {row, column} = this.editor.getCursorScreenPosition()
    if (row < newFirstRow + offset) {
      const newPoint = [row + count, column]
      this.editor.setCursorScreenPosition(newPoint, {autoscroll: false})
    }
  }
}
ScrollDown.initClass()

// ctrl-y scroll lines upwards
class ScrollUp extends ScrollWithoutChangingCursorPosition {
  execute() {
    const count = this.getCount()
    const oldFirstRow = this.editor.getFirstVisibleScreenRow()
    this.editor.setFirstVisibleScreenRow(oldFirstRow - count)
    const newLastRow = this.editor.getLastVisibleScreenRow()

    const offset = 2
    const {row, column} = this.editor.getCursorScreenPosition()
    if (row >= newLastRow - offset) {
      const newPoint = [row - count, column]
      this.editor.setCursorScreenPosition(newPoint, {autoscroll: false})
    }
  }
}
ScrollUp.initClass()

// ScrollWithoutChangingCursorPosition without Cursor Position change.
// -------------------------
class ScrollCursor extends ScrollWithoutChangingCursorPosition {
  initialize() {
    this.moveToFirstCharacterOfLine = true
  }

  execute() {
    if (this.moveToFirstCharacterOfLine) this.editor.moveToFirstCharacterOfLine()
    if (this.isScrollable()) this.editorElement.setScrollTop(this.getScrollTop())
  }

  getOffSetPixelHeight(lineDelta = 0) {
    return this.editor.getLineHeightInPixels() * (this.scrolloff + lineDelta)
  }
}
ScrollCursor.initClass(false)

// z enter
class ScrollCursorToTop extends ScrollCursor {
  isScrollable() {
    return this.getLastVisibleScreenRow() !== this.getLastScreenRow()
  }

  getScrollTop() {
    return this.getCursorPixel().top - this.getOffSetPixelHeight()
  }
}
ScrollCursorToTop.initClass()

// zt
class ScrollCursorToTopLeave extends ScrollCursorToTop {
  initialize() {
    this.moveToFirstCharacterOfLine = false
  }
}
ScrollCursorToTopLeave.initClass()

// z-
class ScrollCursorToBottom extends ScrollCursor {
  isScrollable() {
    return this.getFirstVisibleScreenRow() !== 0
  }

  getScrollTop() {
    return this.getCursorPixel().top - (this.editorElement.getHeight() - this.getOffSetPixelHeight(1))
  }
}
ScrollCursorToBottom.initClass()

// zb
class ScrollCursorToBottomLeave extends ScrollCursorToBottom {
  initialize() {
    this.moveToFirstCharacterOfLine = false
  }
}
ScrollCursorToBottomLeave.initClass()

// z.
class ScrollCursorToMiddle extends ScrollCursor {
  isScrollable() {
    return true
  }

  getScrollTop() {
    return this.getCursorPixel().top - this.editorElement.getHeight() / 2
  }
}
ScrollCursorToMiddle.initClass()

// zz
class ScrollCursorToMiddleLeave extends ScrollCursorToMiddle {
  initialize() {
    this.moveToFirstCharacterOfLine = false
  }
}
ScrollCursorToMiddleLeave.initClass()

// Horizontal ScrollWithoutChangingCursorPosition
// -------------------------
// zs
class ScrollCursorToLeft extends ScrollWithoutChangingCursorPosition {
  execute() {
    this.editorElement.setScrollLeft(this.getCursorPixel().left)
  }
}
ScrollCursorToLeft.initClass()

// ze
class ScrollCursorToRight extends ScrollCursorToLeft {
  execute() {
    this.editorElement.setScrollRight(this.getCursorPixel().left)
  }
}
ScrollCursorToRight.initClass()

// insert-mode specific commands
// -------------------------
class InsertMode extends MiscCommand {}
InsertMode.commandScope = "atom-text-editor.vim-mode-plus.insert-mode"

class ActivateNormalModeOnce extends InsertMode {
  initialize() {
    this.thisCommandName = this.getCommandName()
  }

  execute() {
    const cursorsToMoveRight = this.editor.getCursors().filter(cursor => !cursor.isAtBeginningOfLine())
    this.vimState.activate("normal")
    for (const cursor of cursorsToMoveRight) {
      moveCursorRight(cursor)
    }

    let disposable = atom.commands.onDidDispatch(({type}) => {
      if (type === this.thisCommandName) return

      disposable.dispose()
      disposable = null
      this.vimState.activate("insert")
    })
  }
}
ActivateNormalModeOnce.initClass()

class InsertRegister extends InsertMode {
  initialize() {
    this.requireInput = true
    this.readChar()
  }

  execute() {
    this.editor.transact(() => {
      for (const selection of this.editor.getSelections()) {
        const text = this.vimState.register.getText(this.input, selection)
        selection.insertText(text)
      }
    })
  }
}
InsertRegister.initClass()

class InsertLastInserted extends InsertMode {
  static initClass(...args) {
    super.initClass(...args)
    this.description = "Insert text inserted in latest insert-mode(*i_CTRL-A* of pure Vim)."
  }
  execute() {
    const text = this.vimState.register.getText(".")
    this.editor.insertText(text)
  }
}
InsertLastInserted.initClass()

class CopyFromLineAbove extends InsertMode {
  static initClass(...args) {
    super.initClass(...args)
    this.description = "Insert character of same-column of above line(*i_CTRL-Y* of pure Vim)."
  }

  initialize() {
    this.rowDelta = -1
  }

  execute() {
    const translation = [this.rowDelta, 0]
    this.editor.transact(() => {
      for (let selection of this.editor.getSelections()) {
        const point = selection.cursor.getBufferPosition().translate(translation)
        if (point.row < 0) continue

        const range = Range.fromPointWithDelta(point, 0, 1)
        const text = this.editor.getTextInBufferRange(range)
        if (text) selection.insertText(text)
      }
    })
  }
}
CopyFromLineAbove.initClass()

class CopyFromLineBelow extends CopyFromLineAbove {
  static initClass(...args) {
    super.initClass(...args)
    this.description = "Insert character of same-column of above line.(*i_CTRL-E* of pure Vim)."
  }
  initialize() {
    this.rowDelta = +1
  }
}
CopyFromLineBelow.initClass()

class NextTab extends MiscCommand {
  initialize() {
    this.defaultCount = 0
  }

  execute() {
    const count = this.getCount()
    const pane = atom.workspace.paneForItem(this.editor)
    if (count) {
      pane.activateItemAtIndex(count - 1)
    } else {
      pane.activateNextItem()
    }
  }
}
NextTab.initClass()

class PreviousTab extends MiscCommand {
  execute() {
    atom.workspace.paneForItem(this.editor).activatePreviousItem()
  }
}
PreviousTab.initClass()