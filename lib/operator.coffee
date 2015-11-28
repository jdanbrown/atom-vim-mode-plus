# Refactoring status: 80%
_ = require 'underscore-plus'
{Point, Range, CompositeDisposable} = require 'atom'

{haveSomeSelection} = require './utils'
swrap = require './selection-wrapper'
settings = require './settings'
Base = require './base'

class OperatorError extends Base
  @extend(false)
  constructor: (@message) ->
    @name = 'Operator Error'

# General Operator
# -------------------------
class Operator extends Base
  @extend(false)
  recordable: true
  target: null
  flashTarget: true
  preCompose: null

  haveSomeSelection: ->
    haveSomeSelection(@editor.getSelections())

  isSameOperatorRepeated: ->
    if @vimState.isMode('operator-pending')
      @vimState.operationStack.peekTop().constructor is @constructor
    else
      false

  needFlash: ->
    @flashTarget and settings.get('flashOnOperate') and not @instanceof('Select')

  constructor: ->
    super
    @compose @new(@preCompose) if @preCompose?
    #  To support, `dd`, `cc` and a like.
    if @isSameOperatorRepeated()
      @vimState.operationStack.run 'MoveToRelativeLine'
      @abort()
    @initialize?()

  observeSelectAction: ->
    @onDidSelect =>
      if @needFlash()
        @flash @editor.getSelectedBufferRanges()

    @onWillSelect =>
      switch @getCursorPositionInstruction()
        when 'pointBeforeSelect'
          @finish = @preservePoints()
        when 'pointBeforeSelectAsMarker'
          @finish = @preservePointsAsMarker()
        when 'startPointOfSelection'
          @onDidSelect =>
            @finish = @preservePoints()
        when 'firstCharacterOfStartLineOfSelection'
          @onDidSelect =>
            restorePoints = @preservePoints()
            @finish = (selection, i) ->
              restorePoints(selection, i)
              selection.cursor.moveToFirstCharacterOfLine()

  # target - TextObject or Motion to operate on.
  compose: (@target) ->
    unless _.isFunction(@target.select)
      @vimState.emitter.emit('did-fail-to-compose')
      message = "Failed to compose #{@constructor.name} with #{@target.constructor.name}"
      throw new OperatorError(message)

    if _.isFunction(@target.onDidComposeBy)
      @target.onDidComposeBy(this)

  selectTarget: (force=false) ->
    @observeSelectAction()
    @emitWillSelect()
    if @haveSomeSelection() and not force
      @emitDidSelect()
      true
    else
      @target.select()
      @haveSomeSelection()

  setTextToRegister: (text) ->
    if @target?.isLinewise?() and not text.endsWith('\n')
      text += "\n"
    if text
      @vimState.register.set({text})

  flash: (range) ->
    if @flashTarget and settings.get('flashOnOperate')
      @vimState.flasher.flash range,
        class: 'vim-mode-plus-flash'
        timeout: settings.get('flashOnOperateDuration')

  preservePoints: ->
    points = _.pluck(@editor.getSelectedBufferRanges(), 'start')
    (selection, i) ->
      selection.cursor.setBufferPosition(points[i])

  preservePointsAsMarker: ->
    options = {invalidate: 'never', persistent: false}
    markers = @editor.getCursorBufferPositions().map (point) =>
      @editor.markBufferPosition point, options
    (selection, i) ->
      point = markers[i].getStartBufferPosition()
      selection.cursor.setBufferPosition(point)

  getCursorPositionInstruction: ->
    return null unless @cursorPositionOnOperate?
    {config, stayOnLinewise, stay, default: _default} = @cursorPositionOnOperate
    if settings.get(config) or (@target.isLinewise?() and stayOnLinewise)
      stay
    else
      _default

  # restoreCursor would be set to one of following value,
  #  point: original cursor position
  #  marker: mark original cursor position
  #  start: start point of selection after @target.select()
  #  firstChar: first char of start line of selection after @target.select()
  eachSelection: (fn) ->
    # console.log 'in eachSelection'
    return unless @selectTarget()
    @editor.transact =>
      for selection, i in @editor.getSelections()
        fn(selection)
        @finish?(selection, i)
    # console.log 'out eachSelection'
    # console.log '----------------'

class Select extends Operator
  @extend(false)
  execute: ->
    @selectTarget(true)

class Delete extends Operator
  @extend()
  hover: icon: ':delete:', emoji: ':scissors:'
  flashTarget: false
  execute: ->
    @eachSelection (s) =>
      @setTextToRegister s.getText() if s.isLastSelection()
      s.deleteSelectedText()
      s.cursor.skipLeadingWhitespace() if @target.isLinewise?()
    @vimState.activate('normal')

class DeleteRight extends Delete
  @extend()
  preCompose: 'MoveRight'

class DeleteLeft extends Delete
  @extend()
  preCompose: 'MoveLeft'

class DeleteToLastCharacterOfLine extends Delete
  @extend()
  preCompose: 'MoveToLastCharacterOfLine'

class TransformString extends Operator
  @extend(false)
  cursorPositionOnOperate:
    default: 'startPointOfSelection'
    stay: 'pointBeforeSelect'
    config: 'stayOnTransformString'
    stayOnLinewise: true

  execute: ->
    @eachSelection (s) =>
      s.insertText @getNewText(s.getText())
    @vimState.activate('normal')

class ToggleCase extends TransformString
  @extend()
  hover: icon: ':toggle-case:', emoji: ':clap:'
  toggleCase: (char) ->
    if (charLower = char.toLowerCase()) is char
      char.toUpperCase()
    else
      charLower

  getNewText: (text) ->
    text.split('').map(@toggleCase).join('')

class ToggleCaseAndMoveRight extends ToggleCase
  @extend()
  cursorPositionOnOperate: null
  hover: null
  preCompose: 'MoveRight'

class UpperCase extends TransformString
  @extend()
  hover: icon: ':upper-case:', emoji: ':point_up:'
  getNewText: (text) ->
    text.toUpperCase()

class LowerCase extends TransformString
  @extend()
  hover: icon: ':lower-case:', emoji: ':point_down:'
  getNewText: (text) ->
    text.toLowerCase()

class CamelCase extends TransformString
  @extend()
  hover: icon: ':camel-case:', emoji: ':camel:'
  getNewText: (text) ->
    _.camelize text

class SnakeCase extends TransformString
  @extend()
  hover: icon: ':snake-case:', emoji: ':snake:'
  getNewText: (text) ->
    _.underscore text

class DashCase extends TransformString
  @extend()
  hover: icon: ':dash-case:', emoji: ':dash:'
  getNewText: (text) ->
    _.dasherize text

class Surround extends TransformString
  @extend()
  pairs: ['[]', '()', '{}', '<>']
  input: null
  charsMax: 1
  hover: icon: ':surround:', emoji: ':two_women_holding_hands:'
  requireInput: true

  initialize: ->
    return unless @requireInput
    @onDidConfirmInput (input) => @onConfirm(input)
    @onDidChangeInput (input) => @vimState.hover.add(input)
    @onDidCancelInput => @vimState.operationStack.cancel()
    @vimState.input.focus({@charsMax})

  onConfirm: (@input) ->
    @vimState.operationStack.process()

  getPair: (input) ->
    pair = _.detect @pairs, (pair) -> input in pair
    pair ?= input + input

  surround: (text, pair) ->
    [open, close] = pair.split('')
    open + text + close

  getNewText: (text) ->
    @surround text, @getPair(@input)

class SurroundWord extends Surround
  @extend()
  preCompose: 'Word'

class DeleteSurround extends Surround
  @extend()
  pairChars: ['[]', '()', '{}'].join('')

  onConfirm: (@input) ->
    # FIXME: dont manage allowNextLine independently. Each Pair text-object can handle by themselvs.
    target = @new 'Pair',
      pair: @getPair(@input)
      inclusive: true
      allowNextLine: @input in @pairChars
    @compose(target)
    @vimState.operationStack.process()

  getNewText: (text) ->
    text[1...-1]

class DeleteSurroundAnyPair extends DeleteSurround
  @extend()
  requireInput: false
  preCompose: 'AnyPair'

class ChangeSurround extends DeleteSurround
  @extend()
  charsMax: 2
  char: null

  onConfirm: (input) ->
    return unless input
    [from, @char] = input.split('')
    super(from)

  getNewText: (text) ->
    @surround super(text), @getPair(@char)

class ChangeSurroundAnyPair extends ChangeSurround
  @extend()
  charsMax: 1
  preCompose: "AnyPair"

  initialize: ->
    @restore = @preservePoints()
    @target.select()
    unless @haveSomeSelection()
      @vimState.reset()
      @abort()
    @vimState.hover.add(@editor.getSelectedText()[0])
    super

  onConfirm: (@char) ->
    # Clear pre-selected selection to start @eachSelection from non-selection.
    @restore(s, i) for s, i in @editor.getSelections()
    @input = @char
    @vimState.operationStack.process()

class Yank extends Operator
  @extend()
  hover: icon: ':yank:', emoji: ':clipboard:'
  cursorPositionOnOperate:
    default: 'startPointOfSelection'
    stay: 'pointBeforeSelect'
    config: 'stayOnYank'
    stayOnLinewise: true

  execute: ->
    @eachSelection (s) =>
      @setTextToRegister s.getText() if s.isLastSelection()
    @vimState.activate('normal')

class YankLine extends Yank
  @extend()
  preCompose: 'MoveToRelativeLine'

class Join extends Operator
  @extend()
  complete: true
  execute: ->
    @editor.transact =>
      _.times @getCount(), =>
        @editor.joinLines()
    @vimState.activate('normal')

class Repeat extends Operator
  @extend()
  complete: true
  recordable: false
  execute: ->
    @editor.transact =>
      _.times @getCount(), =>
        if op = @vimState.operationStack.getRecorded()
          op.setRepeated()
          op.execute()

class Mark extends Operator
  @extend()
  hover: icon: ':mark:', emoji: ':round_pushpin:'
  requireInput: true
  initialize: ->
    @focusInput()

  execute: ->
    @vimState.mark.set(@input, @editor.getCursorBufferPosition())
    @vimState.activate('normal')

# [FIXME?]: inconsistent behavior from normal operator
# Since its support visual-mode but not use @target and compose convension.
# Maybe separating complete/in-complete version like IncreaseNow and Increase?
class Increase extends Operator
  @extend()
  complete: true
  step: 1

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g

    newRanges = []
    @editor.transact =>
      for c in @editor.getCursors()
        scanRange = if @vimState.isMode('visual')
          c.selection.getBufferRange()
        else
          c.getCurrentLineBufferRange()
        ranges = @increaseNumber(c, scanRange, pattern)
        if not @vimState.isMode('visual') and ranges.length
          c.setBufferPosition ranges[0].end.translate([0, -1])
        newRanges.push ranges

    if (newRanges = _.flatten(newRanges)).length
      @flash newRanges
    else
      atom.beep()

  increaseNumber: (cursor, scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, range, stop, replace}) =>
      newText = String(parseInt(matchText, 10) + @step * @getCount())
      if @vimState.isMode('visual')
        newRanges.push replace(newText)
      else
        return unless range.end.isGreaterThan cursor.getBufferPosition()
        newRanges.push replace(newText)
        stop()
    newRanges

class Decrease extends Increase
  @extend()
  step: -1

class IncrementNumber extends Operator
  @extend()
  step: 1
  baseNumber: null

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g
    newRanges = null
    @selectTarget()
    @editor.transact =>
      newRanges = for s in @editor.getSelectionsOrderedByBufferPosition()
        @replaceNumber(s.getBufferRange(), pattern)
    if (newRanges = _.flatten(newRanges)).length
      @flash newRanges
    else
      atom.beep()
    # Reverseing selection put cursor on start position of selection.
    # This allow increment/decrement works in same target range when repeated.
    swrap.setReversedState(@editor, true)
    @vimState.activate('normal')

  replaceNumber: (scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, replace}) =>
      newRanges.push replace(@getNewText(matchText))
    newRanges

  getNewText: (text) ->
    @baseNumber = if @baseNumber?
      @baseNumber + @step * @getCount()
    else
      parseInt(text, 10)
    String(@baseNumber)

class DecrementNumber extends IncrementNumber
  @extend()
  step: -1

class Indent extends Operator
  @extend()
  hover: icon: ':indent:', emoji: ':point_right:'
  cursorPositionOnOperate:
    default: 'firstCharacterOfStartLineOfSelection'
    stay: 'pointBeforeSelect'
    config: 'stayOnIndent'

  execute: ->
    @eachSelection (s) =>
      @indent(s)
    @vimState.activate('normal')

  indent: (s) ->
    s.indentSelectedRows()

class Outdent extends Indent
  @extend()
  hover: icon: ':outdent:', emoji: ':point_left:'
  indent: (s) ->
    s.outdentSelectedRows()

class AutoIndent extends Indent
  @extend()
  hover: icon: ':auto-indent:', emoji: ':open_hands:'
  indent: (s) ->
    s.autoIndentSelectedRows()

# Put
# -------------------------
class PutBefore extends Operator
  @extend()
  complete: true
  location: 'before'

  execute: ->
    {text, type} = @vimState.register.get()
    return unless text
    text = _.multiplyString(text, @getCount())
    paste = switch
      when type is 'linewise', @vimState.isMode('visual', 'linewise')
        @pasteLinewise
      when 'character'
        @pasteCharacterwise

    @editor.transact =>
      paste(s, text) for s in @editor.getSelections()
    @vimState.activate('normal')

  pasteLinewise: (selection, text) => # fat
    cursor = selection.cursor
    if selection.isEmpty()
      if @location is 'before'
        cursor.moveToBeginningOfLine()
        selection.insertText("\n")
        cursor.moveUp()
      else
        cursor.moveToEndOfLine()
        selection.insertText("\n")
      text = text.replace(/\n$/, '')
    else
      if @vimState.isMode('visual', 'linewise')
        text += '\n' unless text.endsWith('\n')
      else
        selection.insertText("\n")
    range = selection.insertText(text)
    @flash range
    cursor.setBufferPosition(range.start)
    cursor.moveToFirstCharacterOfLine()

  pasteCharacterwise: (selection, text) => # fat
    cursor = selection.cursor
    if @location is 'after' and selection.isEmpty()
      cursor.moveRight()
    range = selection.insertText(text)
    @flash range
    cursor.setBufferPosition(range.end.translate([0, -1]))

class PutAfter extends PutBefore
  @extend()
  location: 'after'

class ReplaceWithRegister extends Operator
  @extend()
  hover: icon: ':replace-with-register:', emoji: ':pencil:'
  cursorPositionOnOperate:
    default: 'startPointOfSelection'
    stay: 'pointBeforeSelect'
    config: 'stayOnReplaceWithRegister'
  execute: ->
    @eachSelection (s) =>
      newText = @vimState.register.getText() ? s.getText()
      s.insertText(newText)
    @vimState.activate('normal')

class ToggleLineComments extends Operator
  @extend()
  hover: icon: ':toggle-line-comment:', emoji: ':mute:'
  cursorPositionOnOperate:
    default: 'pointBeforeSelectAsMarker'
  execute: ->
    @eachSelection (s) ->
      s.toggleLineComments()
    @vimState.activate('normal')

# Replace
# -------------------------
# [FIXME] need rewrite
class Replace extends Operator
  @extend()
  input: null
  hover: icon: 'r', emoji: ':tractor:'

  requireInput: true

  initialize: ->
    @focusInput()

  isComplete: ->
    @input = "\n" if @input is ''
    super

  execute: ->
    count = @getCount()

    @editor.transact =>
      if @target?
        if @selectTarget()
          @editor.replaceSelectedText null, (text) =>
            text.replace(/./g, @input)
          for selection in @editor.getSelections()
            point = selection.getBufferRange().start
            selection.setBufferRange(Range.fromPointWithDelta(point, 0, 0))
      else
        for cursor in @editor.getCursors()
          pos = cursor.getBufferPosition()
          currentRowLength = @editor.lineTextForBufferRow(pos.row).length
          continue unless currentRowLength - pos.column >= count

          _.times count, =>
            point = cursor.getBufferPosition()
            @editor.setTextInBufferRange(Range.fromPointWithDelta(point, 0, 1), @input)
            cursor.moveRight()
          cursor.setBufferPosition(pos)

        # Special case: when replaced with a newline move to the start of the
        # next row.
        if @input is "\n"
          _.times count, =>
            @editor.moveDown()
          @editor.moveToFirstCharacterOfLine()

    @vimState.activate('normal')

# Input
# -------------------------
# The operation for text entered in insert-mode. Broadly speaking, input
# operators manage an undo transaction and set a @typingCompleted variable when
# it's done. When the input operation is completed, the typingCompleted variable
# tells the operation to repeat itself instead of enter insert mode.
class ActivateInsertMode extends Operator
  @extend()
  complete: true
  flashTarget: false
  checkpoint: null
  submode: null

  initialize: ->
    @checkpoint = {}
    @setCheckpoint('undo') unless @isRepeated()

  # we have to manage two separate checkpoint for different purpose(timing is different)
  # - one for undo(handled by modeManager)
  # - one for preserve last inserted text
  setCheckpoint: (purpose) ->
    @checkpoint[purpose] = @editor.createCheckpoint()

  getCheckpoint: ->
    @checkpoint

  getText: ->
    @vimState.register.getText('.')

  # called when repeated
  insertText: (selection, text) ->
    selection.insertText(text, autoIndent: true)

  execute: ->
    if @isRepeated()
      return unless text = @getText()
      @editor.transact =>
        for selection in @editor.getSelections()
          {cursor} = selection
          @insertText(selection, text)
          cursor.moveLeft() unless cursor.isAtBeginningOfLine()
    else
      @setCheckpoint('insert')
      @vimState.activate('insert', @submode)

class InsertAtLastInsert extends ActivateInsertMode
  @extend()
  execute: ->
    if (point = @vimState.mark.get('^'))
      @editor.setCursorBufferPosition(point)
      @editor.scrollToCursorPosition({center: true})
    super

class ActivateReplaceMode extends ActivateInsertMode
  @extend()
  submode: 'replace'

  insertText: (selection, text) ->
    for char in text when char isnt "\n"
      break if selection.cursor.isAtEndOfLine()
      selection.selectRight()
    selection.insertText(text, autoIndent: false)

class InsertAfter extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveRight() unless @editor.getLastCursor().isAtEndOfLine()
    super

class InsertAfterEndOfLine extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveToEndOfLine()
    super

class InsertAtBeginningOfLine extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveToFirstCharacterOfLine()
    super

# FIXME need support count
class InsertAboveWithNewline extends ActivateInsertMode
  @extend()
  execute: ->
    @insertNewline()
    super

  insertNewline: ->
    @editor.insertNewlineAbove()

  insertText: (selection, text) ->
    selection.insertText(text.trimLeft(), autoIndent: true)

class InsertBelowWithNewline extends InsertAboveWithNewline
  @extend()
  insertNewline: ->
    @editor.insertNewlineBelow()

class Change extends ActivateInsertMode
  @extend()
  complete: false

  execute: ->
    @target.setOptions?(excludeWhitespace: true)
    if @selectTarget()
      @setTextToRegister @editor.getSelectedText()
      text = if @target.isLinewise?() then "\n" else ""
      for s in @editor.getSelections()
        range = s.insertText(text, autoIndent: true)
        s.cursor.moveLeft() unless range.isEmpty()
    super

class Substitute extends Change
  @extend()
  preCompose: 'MoveRight'

class SubstituteLine extends Change
  @extend()
  preCompose: 'MoveToRelativeLine'

class ChangeToLastCharacterOfLine extends Change
  @extend()
  preCompose: 'MoveToLastCharacterOfLine'
