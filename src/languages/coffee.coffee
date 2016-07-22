# Droplet CoffeeScript mode
#
# Copyright (c) Anthony Bau (dab1998@gmail.com)
# MIT License

helper = require '../helper.coffee'
model = require '../model.coffee'
parser = require '../parser.coffee'

{fixQuotedString, looseCUnescape, quoteAndCEscape} = helper

{CoffeeScript} = require '../../vendor/coffee-script.js'

{
  ANY_DROP
  BLOCK_ONLY
  MOSTLY_BLOCK
  MOSTLY_VALUE
  VALUE_ONLY
} = helper

KNOWN_FUNCTIONS =
  'alert'       : {}
  'prompt'      : {}
  'console.log' : {}
  '*.toString'  : {}
  'Math.abs'    : {value: true}
  'Math.acos'   : {value: true}
  'Math.asin'   : {value: true}
  'Math.atan'   : {value: true}
  'Math.atan2'  : {value: true}
  'Math.cos'    : {value: true}
  'Math.sin'    : {value: true}
  'Math.tan'    : {value: true}
  'Math.ceil'   : {value: true}
  'Math.floor'  : {value: true}
  'Math.round'  : {value: true}
  'Math.exp'    : {value: true}
  'Math.ln'     : {value: true}
  'Math.log10'  : {value: true}
  'Math.pow'    : {value: true}
  'Math.sqrt'   : {value: true}
  'Math.max'    : {value: true}
  'Math.min'    : {value: true}
  'Math.random' : {value: true}

STATEMENT_KEYWORDS = [
  'break'
  'continue'
]

CATEGORIES = {
  functions: {color: 'purple'}
  returns: {color: 'yellow'}
  comments: {color: 'gray'}
  arithmetic: {color: 'green'}
  logic: {color: 'cyan'}
  containers: {color: 'teal'}
  assignments: {color: 'blue'}
  loops: {color: 'orange'}
  conditionals: {color: 'orange'}
  value: {color: 'green'}
  command: {color: 'blue'}
  errors: {color: '#f00'}
}

NODE_CATEGORY = {
  Parens: 'command'
  Op: 'value'         # overridden by operator test
  Existence: 'logic'
  In: 'logic'
  Value: 'value'
  Literal: 'value'    # overridden by break, continue, errors
  Call: 'command'     # overridden by complicated logic
  Code: 'functions'
  Class: 'functions'
  Assign: 'assignments'  # overriden by test for function definition
  For: 'loops'
  While: 'loops'
  If: 'conditionals'
  Switch: 'conditionals'
  Range: 'containers'
  Arr: 'containers'
  Obj: 'containers'
  Return: 'returns'
}

LOGICAL_OPERATORS = {
  '==': true
  '!=': true
  '===': true
  '!==': true
  '<': true
  '<=': true
  '>': true
  '>=': true
  'in': true
  'instanceof': true
  '||': true
  '&&': true
  '!': true
}

###
OPERATOR_PRECEDENCES =
  '*': 5
  '/': 5
  '%': 5
  '+': 6
  '-': 6
  '<<': 7
  '>>': 7
  '>>>': 7
  '<': 8
  '>': 8
  '>=': 8
  'in': 8
  'instanceof': 8
  '==': 9
  '!=': 9
  '===': 9
  '!==': 9
  '&': 10
  '^': 11
  '|': 12
  '&&': 13
  '||': 14
###

OPERATOR_PRECEDENCES =
  '||': 1
  '&&': 2
  'instanceof': 3
  '===': 3
  '!==': 3
  '>': 3
  '<': 3
  '>=': 3
  '<=': 3
  '+': 4
  '-': 4
  '*': 5
  '/': 5
  '%': 6
  '**': 7
  '%%': 7

PRECEDENCES = {
  'Semicolon': -3
  'Range': 100
  'Arr': 100
  'PropertyAccess': 100
  'For': -4
  'While': -4
  'Expression' : 0
  'Call': 0
  'LastCallArg': -1
}

for operator, precedence of OPERATOR_PRECEDENCES
  PRECEDENCES['Operator' + operator] = precedence

getPrecedence = (type) ->
  PRECEDENCES[type] ? 0

YES = -> yes
NO = -> no

spacestring = (n) -> (' ' for [0...Math.max(0, n)]).join('')

annotateCsNodes = (tree) ->
  tree.eachChild (child) ->
    child.dropletParent = tree
    annotateCsNodes child
  return tree

exports.CoffeeScriptParser = class CoffeeScriptParser extends parser.Parser
  constructor: (@text, opts) ->
    super

    @opts.functions ?= KNOWN_FUNCTIONS
    @opts.categories = helper.extend({}, CATEGORIES, @opts.categories)

    @lines = @text.split '\n'

    @hasLineBeenMarked = {}

    for line, i in @lines
      @hasLineBeenMarked[i] = false

  markRoot: ->
    # Preprocess comments
    retries = Math.max(1, Math.min(5, Math.ceil(@lines.length / 2)))
    firstError = null
    # Get the CoffeeScript AST from the text
    loop
      try
        do @stripComments

        tree = CoffeeScript.nodes(@text)
        annotateCsNodes tree
        nodes = tree.expressions
        break
      catch e
        firstError ?= e
        if retries > 0 and fixCoffeeScriptError @lines, e
          @text = @lines.join '\n'
        else
          # If recovery isn't possible, insert a loc object with
          # the possible location of the error, and throw the error.
          if firstError.location
            firstError.loc =
              line: firstError.location.first_line
              column: firstError.location.first_column
          throw firstError
      retries -= 1

    # Mark all the nodes
    # in the block.
    for node in nodes
      @mark node, 3, null, 0

    # Deal with semicoloned lines
    # at the root level
    @wrapSemicolons nodes, 0

  isComment: (str) ->
    str.match(/^\s*#.*$/)?

  parseComment: (str) ->
    {
      sockets: [[str.match(/^\s*#/)?[0].length, str.length]]
    }

  stripComments: ->
    # Preprocess comment lines:
    try
      tokens = CoffeeScript.tokens @text,
        rewrite: false
        preserveComments: true
    catch syntaxError
      # Right now, we do not attempt to recover from failures in tokenization
      if syntaxError.location
        syntaxError.loc =
          line: syntaxError.location.first_line
          column: syntaxError.location.first_column
      throw syntaxError

    # In the @lines record, replace all
    # comments with spaces, so that blocks
    # avoid them whenever possible.
    for token in tokens
      if token[0] is 'COMMENT'

        if token[2].first_line is token[2].last_line
          line = @lines[token[2].first_line]
          @lines[token[2].first_line] =
            line[...token[2].first_column] +
            spacestring(token[2].last_column - token[2].first_column + 1) +
            line[token[2].last_column...]

        else
          line = @lines[token[2].first_line]
          @lines[token[2].first_line] = line[...token[2].first_column] +
            spacestring(line.length - token[2].first_column)

          @lines[token[2].last_line] =
            spacestring(token[2].last_column + 1) +
              @lines[token[2].last_line][token[2].last_column + 1...]

          for i in [(token[2].first_line + 1)...token[2].last_line]
            @lines[i] = spacestring(@lines[i].length)

    # We will leave comments unmarked
    # until the applyMarkup postprocessing
    # phase, when they will be surrounded
    # by blocks if they are outside anything else.
    return null

  functionNameNodes: (node) ->
    if node.nodeType() isnt 'Call' then throw new Error
    if node.variable?
      # Two possible forms of a Call node:
      # fn(...) ->
      #    node.variable.base = fn
      # x.y.z.fn()
      #    node.variable.base = x
      #    properties = [y, z, fn]
      nodes = []
      if node.variable.base?.value
        nodes.push node.variable.base
      else
        nodes.push null
      if node.variable.properties?
        for prop in node.variable.properties
            nodes.push prop.name
      return nodes
    return []

  emptyLocation: (loc) ->
    loc.first_column is loc.last_column and loc.first_line is loc.last_line

  implicitName: (nn) ->
    # Deal with weird coffeescript rewrites, e.g., /// #{x} ///
    # is rewritten to RegExp(...)
    if nn.length is 0 then return false
    node = nn[nn.length - 1]
    return node?.value?.length > 1 and @emptyLocation node.locationData

  lookupFunctionName: (nn) ->
    # Test the name nodes list against the given list, and return
    # null if not found, or a tuple of information about the match.
    full = (nn.map (n) -> n?.value or '*').join '.'
    if full of @opts.functions
      return name: full, anyobj: false, fn: @opts.functions[full]
    last = nn[nn.length - 1]?.value
    if nn.length > 1 and (wildcard = '*.' + last) not of @opts.functions
      wildcard = null  # no match for '*.name'
    if not wildcard and (wildcard = '?.' + last) not of @opts.functions
      wildcard = null  # no match for '?.name'
    if wildcard isnt null
      return name: last, anyobj: true, fn: @opts.functions[wildcard]
    return null

  # ## addCode ##
  # This shared logic handles the sockets for the Code function
  # definitions, even when merged into a parent block.
  addCode: (node, depth, indentDepth) ->
    # Combining all the parameters into one socket
    if node.params?.length ? 0 > 0
      @addSocket {
        bounds: @boundCombine @getBounds(node.params[0]), @getBounds(node.params[node.params.length - 1])
        depth,
        dropdown: null,
        parseContext: '__comment__'
        empty: ''
      }

    # If there are no parameters, attempt to insert an empty socket so the user can add some
    else
      nodeBoundsStart = @getBounds(node).start
      match = @lines[nodeBoundsStart.line][nodeBoundsStart.column..].match(/^(\s*\()(\s*)\)\s*(-|=)>/)
      if match?
        @addSocket {
          bounds: {
            start: {
              line: nodeBoundsStart.line
              column: nodeBoundsStart.column + match[1].length
            }
            end: {
              line: nodeBoundsStart.line
              column: nodeBoundsStart.column + match[1].length + match[2].length
            }
          },
          depth,
          dropdown: null,
          parseContext: '__comment__'
          empty: ''
        }
    @mark node.body, depth, null, indentDepth

  # ## mark ##
  # Mark a single node.  The main recursive function.
  mark: (node, depth, wrappingParen, indentDepth) ->

    switch node.nodeType()

      # ### Block ###
      # A Block is a group of expressions,
      # which is represented by either an indent or a socket.
      when 'Block'
        # Abort if empty
        if node.expressions.length is 0 then return

        # Otherwise, get the bounds to determine
        # whether we want to do it on one line or multiple lines.
        bounds = @getBounds node

        # See if we want to wrap in a socket
        # rather than an indent.
        shouldBeOneLine = false

        # Check to see if any parent node is occupying a line
        # we are on. If so, we probably want to wrap in
        # a socket rather than an indent.
        for line in [bounds.start.line..bounds.end.line]
          shouldBeOneLine or= @hasLineBeenMarked[line]

        if @lines[bounds.start.line][...bounds.start.column].trim().length isnt 0
          shouldBeOneLine = true

        if shouldBeOneLine
          @csSocket node, depth, 'Block'

        # Otherwise, wrap in an indent.
        else
          # Determine the new indent depth by literal text inspection
          textLine = @lines[node.locationData.first_line]
          trueIndentDepth = textLine.length - textLine.trimLeft().length

          # As a block, we also want to consume as much whitespace above us as possible
          # (to free it from actual ICE editor blocks).
          while bounds.start.line > 0 and @lines[bounds.start.line - 1].trim().length is 0
            bounds.start.line -= 1
            bounds.start.column = @lines[bounds.start.line].length + 1

          # Move the boundaries back by one line,
          # as per the standard way to add an Indent.
          bounds.start.line -= 1
          bounds.start.column = @lines[bounds.start.line].length + 1

          @addIndent {
            depth: depth
            bounds: bounds
            prefix: @lines[node.locationData.first_line][indentDepth...trueIndentDepth]
          }

          # Then update indent depth data to reflect.
          indentDepth = trueIndentDepth

        # Mark children. We do this at depth + 3 to
        # make room for semicolon wrappers where necessary.
        for expr in node.expressions
          @mark expr, depth + 3, null, indentDepth

        # Wrap semicolons.
        @wrapSemicolons node.expressions, depth

      # ### Parens ###
      # Parens are special; they get no marks
      # but pass to the next node with themselves
      # as the wrapping parens.
      #
      # If we are ourselves wrapped by a parenthesis,
      # then keep that parenthesis when we pass on.
      when 'Parens'
        if node.body?
          unless node.body.nodeType() is 'Block'
            @mark node.body, depth + 1, (wrappingParen ? node), indentDepth
          else
            if node.body.unwrap() is node.body
              # We are filled with some things
              # connected by semicolons; wrap them all,
              @csBlock node, depth, 'Semicolon', null, MOSTLY_BLOCK

              for expr in node.body.expressions
                @csSocketAndMark expr, depth + 1, 'Expression', indentDepth

            else
              @mark node.body.unwrap(), depth + 1, (wrappingParen ? node), indentDepth

      # ### Op ###
      # Color VALUE, sockets @first and (sometimes) @second
      when 'Op'
        # An addition operator might be
        # a string interpolation, in which case
        # we want to ignore it.
        if node.first? and node.second? and node.operator is '+'
          # We will search for a literal "+" symbol
          # between the two operands. If there is none,
          # we assume string interpolation.
          firstBounds = @getBounds node.first
          secondBounds = @getBounds node.second

          lines = @lines[firstBounds.end.line..secondBounds.start.line].join('\n')

          infix = lines[firstBounds.end.column...-(@lines[secondBounds.start.line].length - secondBounds.start.column)]

          if infix.indexOf('+') is -1
            return

        # Treat unary - and + specially if they surround a literal: then
        # they should just be sucked into the literal.
        if node.first and not node.second and node.operator in ['+', '-'] and
            node.first?.base?.nodeType?() is 'Literal'
          return

        @csBlock node, depth, 'Operator' + node.operator, wrappingParen, VALUE_ONLY

        @csSocketAndMark node.first, depth + 1, 'Operator' + node.operator, indentDepth

        if node.second?
          @csSocketAndMark node.second, depth + 1, 'Operator' + node.operator, indentDepth

      # ### Existence ###
      # Color VALUE, socket @expression
      when 'Existence'
        @csBlock node, depth, 'Existence', wrappingParen, VALUE_ONLY
        @csSocketAndMark node.expression, depth + 1, 'Existence', indentDepth

      # ### In ###
      # Color VALUE, sockets @object and @array
      when 'In'
        @csBlock node, depth, 'In', wrappingParen, VALUE_ONLY
        @csSocketAndMark node.object, depth + 1, 'In', indentDepth
        @csSocketAndMark node.array, depth + 1, 'In', indentDepth

      # ### Value ###
      # Completely pass through to @base; we do not care
      # about this node.
      when 'Value'
        if node.properties? and node.properties.length > 0
          @csBlock node, depth, 'PropertyAccess', wrappingParen, MOSTLY_VALUE
          @csSocketAndMark node.base, depth + 1, 'PropertyAccess', indentDepth
          for property in node.properties
            if property.nodeType() is 'Access'
              @csSocketAndMark property.name, depth + 1, 'Identifier', indentDepth
            else if property.nodeType() is 'Index'
              @csSocketAndMark property.index, depth + 1, 'Expression', indentDepth

        # Fake-remove backticks hack
        else if node.base.nodeType() is 'Literal' and
            (node.base.value is '' or node.base.value is @empty)
          fakeBlock =
              @csBlock node.base, depth, '__flag_to_remove__', wrappingParen, ANY_DROP
          fakeBlock.flagToRemove = true

        # Preserved-error backticks hack
        else if node.base.nodeType() is 'Literal' and
            /^#/.test(node.base.value)
          @csBlock node.base, depth, '__flag_to_strip__', wrappingParen, ANY_DROP
          errorSocket = @csSocket node.base, depth + 1, -2
          errorSocket.flagToStrip = { left: 2, right: 1 }

        else
          @mark node.base, depth + 1, wrappingParen, indentDepth

      # ### Keywords ###
      when 'Literal'
        if node.value in STATEMENT_KEYWORDS
          # handle break and continue
          @csBlock node, depth, 'Keyword', wrappingParen, BLOCK_ONLY
        else
          # otherwise, leave it as a white block
          0

      # ### Literal ###
      # No-op. Translate directly to text
      when 'Literal', 'Bool', 'Undefined', 'Null' then 0

      # ### Call ###
      # Color COMMAND, sockets @variable and @args.
      # We will not add a socket around @variable when it
      # is only some text
      when 'Call'
        hasCallParen = false
        if node.variable?
          namenodes = @functionNameNodes node
          known = @lookupFunctionName namenodes
          if known
            if known.fn.value
              classes = if known.fn.command then ANY_DROP else MOSTLY_VALUE
            else
              classes = MOSTLY_BLOCK
          else
            classes = ANY_DROP
          @csBlock node, depth, 'Call', wrappingParen, classes

          variableBounds = @getBounds(node.variable)
          hasCallParen = (@lines[variableBounds.end.line][variableBounds.end.column] == '(')

          # Some function names (like /// RegExps ///) are never editable.
          if @implicitName namenodes
            # do nothing
          else if not known
            # In the 'advanced' case where the methodname should be
            # editable, treat the whole (x.y.fn) as an expression to socket.
            @csSocketAndMark node.variable, depth + 1, 'Callee', indentDepth
          else if known.anyobj and node.variable.properties?.length > 0
            # In the 'beginner' case of a simple method call with a
            # simple base object variable, let the variable be socketed.
            @csSocketAndMark node.variable.base, depth + 1, 'PropertyAccess', indentDepth

          if not known and node.args.length is 0 and not node.do
            # The only way we can have zero arguments in CoffeeScript
            # is for the parenthesis to open immediately after the function name.
            start = {
              line: variableBounds.end.line
              column: variableBounds.end.column + 1
            }
            end = {
              line: start.line
              column: start.column
            }
            space = @lines[start.line][start.column..].match(/^(\s*)\)/)
            if space?
              end.column += space[1].length
            @addSocket {
              bounds: {start, end}
              depth,
              dropdown: null,
              parseContext: 'Expression'
              empty: ''
            }
        else
          @csBlock node, depth, 'Call', wrappingParen, ANY_DROP

        unless node.do
          for arg, index in node.args
            last = index is node.args.length - 1
            # special case: the last argument slot of a function
            # gathers anything inside it, without parens needed.
            if last and arg.nodeType() is 'Code'
              # Inline function definitions that appear as the last arg
              # of a function call will be melded into the parent block.
              @addCode arg, depth + 1, indentDepth
            else if last
              @csSocketAndMark arg, depth + 1, 'LastCallArg', indentDepth, known?.fn?.dropdown?[index]
            else if not known and hasCallParen and index is 0 and node.args.length is 1
              @csSocketAndMark arg, depth + 1, 'Expression', indentDepth, known?.fn?.dropdown?[index], ''
            else
              @csSocketAndMark arg, depth + 1, 'Expression', indentDepth, known?.fn?.dropdown?[index]

      # ### Code ###
      # Function definition. Color VALUE, sockets @params,
      # and indent @body.
      when 'Code'
        @csBlock node, depth, 'Function', wrappingParen, VALUE_ONLY
        @addCode node, depth + 1, indentDepth

      # ### Assign ###
      # Color COMMAND, sockets @variable and @value.
      when 'Assign'
        @csBlock node, depth, 'Assign', wrappingParen, MOSTLY_BLOCK
        @csSocketAndMark node.variable, depth + 1, 'Lvalue', indentDepth

        if node.value.nodeType() is 'Code'
          @addCode node.value, depth + 1, indentDepth
        else
          @csSocketAndMark node.value, depth + 1, 'Expression', indentDepth

      # ### For ###
      # Color CONTROL, options sockets @index, @source, @name, @from.
      # Indent/socket @body.
      when 'For'
        @csBlock node, depth, 'For', wrappingParen, MOSTLY_BLOCK

        for childName in ['source', 'from', 'guard', 'step']
          if node[childName]? then @csSocketAndMark node[childName], depth + 1, 'ForModifier', indentDepth

        for childName in ['index', 'name']
          if node[childName]? then @csSocketAndMark node[childName], depth + 1, 'Lvalue', indentDepth

        @mark node.body, depth + 1, null, indentDepth

      # ### Range ###
      # Color VALUE, sockets @from and @to.
      when 'Range'
        @csBlock node, depth, 'Range', wrappingParen, VALUE_ONLY
        @csSocketAndMark node.from, depth, 'Expression', indentDepth
        @csSocketAndMark node.to, depth, 'Expression', indentDepth

      # ### If ###
      # Color CONTROL, socket @condition.
      # indent/socket body, optional indent/socket node.elseBody.
      #
      # Special case: "unless" keyword; in this case
      # we want to skip the Op that wraps the condition.
      when 'If'
        @csBlock node, depth, 'If', wrappingParen, MOSTLY_BLOCK, {addButton: '+'}

        # Check to see if we are an "unless".
        # We will deem that we are an unless if:
        #   - Our starting line contains "unless" and
        #   - Our condition starts at the same location as
        #     ourselves.

        # Note: for now, we have hacked CoffeeScript
        # to give us the raw condition location data.
        #
        # Perhaps in the future we should do this at
        # wrapper level.

        ###
        bounds = @getBounds node
        if @lines[bounds.start.line].indexOf('unless') >= 0 and
            @locationsAreIdentical(bounds.start, @getBounds(node.condition).start) and
            node.condition.nodeType() is 'Op'

          @csSocketAndMark node.condition.first, depth + 1, 0, indentDepth
        else
        ###

        @csSocketAndMark node.rawCondition, depth + 1, 'If', indentDepth

        @mark node.body, depth + 1, null, indentDepth

        currentNode = node

        while currentNode?
          if currentNode.isChain
            currentNode = currentNode.elseBodyNode()
            @csSocketAndMark currentNode.rawCondition, depth + 1, 0, indentDepth
            @mark currentNode.body, depth + 1, null, indentDepth

          else if currentNode.elseBody?
            # Artificially "mark" the line containing the "else"
            # token, so that the following body can be single-line
            # if necessary.
            @flagLineAsMarked currentNode.elseToken.first_line
            @mark currentNode.elseBody, depth + 1, null, indentDepth
            currentNode = null

          else
            currentNode = null

      # ### Arr ###
      # Color VALUE, sockets @objects.
      when 'Arr'
        @csBlock node, depth, 'Arr', wrappingParen, VALUE_ONLY

        if node.objects.length > 0
          @csIndentAndMark indentDepth, node.objects, depth + 1
        for object in node.objects
          if object.nodeType() is 'Value' and object.base.nodeType() is 'Literal' and
              object.properties?.length in [0, undefined]
            @csBlock object, depth + 2, 'Value', null, VALUE_ONLY

      # ### Return ###
      # Color RETURN, optional socket @expression.
      when 'Return'
        @csBlock node, depth, 'Return', wrappingParen, BLOCK_ONLY
        if node.expression?
          @csSocketAndMark node.expression, depth + 1, 'Expression', indentDepth

      # ### While ###
      # Color CONTROL. Socket @condition, socket/indent @body.
      when 'While'
        @csBlock node, depth, 'While', wrappingParen, MOSTLY_BLOCK
        @csSocketAndMark node.rawCondition, depth + 1, 'Expression', indentDepth
        if node.guard? then @csSocketAndMark node.guard, depth + 1, 'Expression', indentDepth
        @mark node.body, depth + 1, null, indentDepth

      # ### Switch ###
      # Color CONTROL. Socket @subject, optional sockets @cases[x][0],
      # indent/socket @cases[x][1]. indent/socket @otherwise.
      when 'Switch'
        @csBlock node, depth, 'Switch', wrappingParen, MOSTLY_BLOCK

        if node.subject? then @csSocketAndMark node.subject, depth + 1, 'Expression', indentDepth

        for switchCase in node.cases
          if switchCase[0].constructor is Array
            for condition in switchCase[0]
              @csSocketAndMark condition, depth + 1, 'Expression', indentDepth # (condition)
          else
            @csSocketAndMark switchCase[0], depth + 1, 'Expression', indentDepth # (condition)
          @mark switchCase[1], depth + 1, null, indentDepth # (body)

        if node.otherwise?
          @mark node.otherwise, depth + 1, null, indentDepth

      # ### Class ###
      # Color CONTROL. Optional sockets @variable, @parent. Optional indent/socket
      # @obdy.
      when 'Class'
        @csBlock node, depth, 'Class', wrappingParen, ANY_DROP

        if node.variable? then @csSocketAndMark node.variable, depth + 1, 'Identifier', indentDepth
        if node.parent? then @csSocketAndMark node.parent, depth + 1, 'Expression', indentDepth

        if node.body? then @mark node.body, depth + 1, null, indentDepth

      # ### Obj ###
      # Color VALUE. Optional sockets @property[x].variable, @property[x].value.
      # TODO: This doesn't quite line up with what we want it to be visually;
      # maybe our View architecture is wrong.
      when 'Obj'
        @csBlock node, depth, 'Obj', wrappingParen, VALUE_ONLY

        for property in node.properties
          if property.nodeType() is 'Assign'
            @csSocketAndMark property.variable, depth + 1, 'Identifier', indentDepth
            @csSocketAndMark property.value, depth + 1, 'Expression', indentDepth


  handleButton: (text, button, oldBlock) ->
    if button is 'add-button' and oldBlock.nodeContext.type is 'If'
      # Parse to find the last "else" or "else if"
      node = CoffeeScript.nodes(text, {
        locations: true
        line: 0
        allowReturnOutsideFunction: true
      }).expressions[0]

      lines = text.split '\n'

      currentNode = node
      elseLocation = null

      while currentNode.isChain
        currentNode = currentNode.elseBodyNode()

      if currentNode.elseBody?
        lines = text.split('\n')
        elseLocation = {
          line: currentNode.elseToken.last_line
          column: currentNode.elseToken.last_column + 2
        }
        elseLocation = lines[...elseLocation.line].join('\n').length + elseLocation.column
        return text[...elseLocation].trimRight() + ' if ``' + (if text[elseLocation...].match(/^ *\n/)? then '' else ' then ') + text[elseLocation..] + '\nelse\n  ``'
      else
        return text + '\nelse\n  ``'

  locationsAreIdentical: (a, b) ->
    return a.line is b.line and a.column is b.column

  boundMin: (a, b) ->
    if a.line < b.line then a
    else if b.line < a.line then b
    else if a.column < b.column then a
    else b

  boundMax: (a, b) ->
    if a.line < b.line then b
    else if b.line < a.line then a
    else if a.column < b.column then b
    else a

  boundCombine: (a, b) ->
    start = @boundMin a.start, b.start
    end = @boundMax a.end, b.end
    return {start, end}

  # ## getBounds ##
  # Get the boundary locations of a CoffeeScript node,
  # using CoffeeScript location data and
  # adjust to deal with some quirks.
  getBounds: (node) ->
    # Most of the time, we can just
    # take CoffeeScript locationData.
    bounds =
      start:
        line: node.locationData.first_line
        column: node.locationData.first_column
      end:
        line: node.locationData.last_line
        column: node.locationData.last_column + 1

    # There are four cases where CoffeeScript
    # actually gets location data wrong.

    # The first is CoffeeScript 'Block's,
    # which give us only the first line.
    # So we need to adjust.
    if node.nodeType() is 'Block'
      # If we have any child expressions,
      # set the end boundary to be the end
      # of the last one
      if node.expressions.length > 0
        bounds.end = @getBounds(node.expressions[node.expressions.length - 1]).end

      #If we have no child expressions, make the bounds actually empty.
      else
        bounds.start = bounds.end

    # The second is 'If' statements,
    # which do not surround the elseBody
    # when it exists.
    if node.nodeType() is 'If'
      bounds.start = @boundMin bounds.start, @getBounds(node.body).start
      bounds.end = @boundMax @getBounds(node.rawCondition).end, @getBounds(node.body).end

      if node.elseBody?
        bounds.end = @boundMax bounds.end, @getBounds(node.elseBody).end

    # The third is 'While', which
    # fails to surround the loop body,
    # or sometimes the loop guard.
    if node.nodeType() is 'While'
      bounds.start = @boundMin bounds.start, @getBounds(node.body).start
      bounds.end = @boundMax bounds.end, @getBounds(node.body).end

      if node.guard?
        bounds.end = @boundMax bounds.end, @getBounds(node.guard).end

    # Hack: Functions should end immediately
    # when their bodies end.
    if node.nodeType() is 'Code' and node.body?
      bounds.end = @getBounds(node.body).end

    # The fourth is general. Sometimes we get
    # spaces at the start of the next line.
    # We don't want those spaces; discard them.
    while @lines[bounds.end.line][...bounds.end.column].trim().length is 0
      bounds.end.line -= 1
      bounds.end.column = @lines[bounds.end.line].length + 1

    # When we have a 'Value' object,
    # its base may have some exceptions in it,
    # in which case we want to pass on to
    # those.
    if node.nodeType() is 'Value'
      bounds = @getBounds node.base

      if node.properties? and node.properties.length > 0
        for property in node.properties
          bounds.end = @boundMax bounds.end, @getBounds(property).end

    # Special case to deal with commas in arrays:
    if node.dropletParent?.nodeType?() is 'Arr' or
       node.dropletParent?.nodeType?() is 'Value' and node.dropletParent.dropletParent?.nodeType?() is 'Arr'
      match = @lines[bounds.end.line][bounds.end.column...].match(/^\s*,\s*/)
      if match?
        bounds.end.column += match[0].length

    return bounds

  # ## getColor ##
  # Looks up color of the given node, respecting options.
  getColor: (node) ->
    category = NODE_CATEGORY[node.nodeType()] or 'command'
    switch node.nodeType()
      when 'Op'
        if LOGICAL_OPERATORS[node.operator]
          category = 'logic'
        else
          category = 'arithmetic'
      when 'Call'
        if node.variable?
          namenodes = @functionNameNodes node
          known = @lookupFunctionName namenodes
          if known
            if known.fn.value
              category = known.fn.color or
                if known.fn.command then 'command' else 'value'
            else
              category = known.fn.color or 'command'
      when 'Assign'
        # Assignments with a function RHS are function definitions
        if node.value.nodeType() is 'Code'
          category = 'functions'
      when 'Literal'
        # Preserved errors
        if /^#/.test(node.value)
          category = 'error'
        # break and continue
        else if node.value in STATEMENT_KEYWORDS
          category = 'returns'
    return @opts.categories[category]?.color or category

  # ## flagLineAsMarked ##
  flagLineAsMarked: (line) ->
    @hasLineBeenMarked[line] = true
    while @lines[line][@lines[line].length - 1] is '\\'
      line += 1
      @hasLineBeenMarked[line] = true

  # ## addMarkup ##
  # Override addMarkup to flagLineAsMarked
  addMarkup: (container, bounds, depth) ->
    super

    @flagLineAsMarked bounds.start.line

    return container

  getNodeContext: (type, node, wrappingParen) ->
    return new parser.PreNodeContext type, 0, 0 # TODO use wrappingParen properly

  # ## csBlock ##
  # A general utility function for adding an Droplet editor
  # block around a given node.
  csBlock: (node, depth, type, wrappingParen, shape, buttons) ->
    @addBlock {
      bounds: @getBounds (wrappingParen ? node)
      depth: depth
      color: @getColor(node)
      buttons: buttons
      shape: shape

      nodeContext: @getNodeContext type, node, wrappingParen
    }

  # Add an indent node and guess
  # at the indent depth
  csIndent: (indentDepth, firstNode, lastNode, depth) ->
    first = @getBounds(firstNode).start
    last = @getBounds(lastNode).end

    if @lines[first.line][...first.column].trim().length is 0
      first.line -= 1
      first.column = @lines[first.line].length

    if first.line isnt last.line
      trueDepth = @lines[last.line].length - @lines[last.line].trimLeft().length
      prefix = @lines[last.line][indentDepth...trueDepth]
    else
      trueDepth = indentDepth + 2
      prefix = '  '

    @addIndent {
      bounds: {
        start: first
        end: last
      }
      depth: depth

      prefix: prefix
    }

    return trueDepth

  csIndentAndMark: (indentDepth, nodes, depth) ->
    trueDepth = @csIndent indentDepth, nodes[0], nodes[nodes.length - 1], depth
    for node in nodes
      @mark node, depth + 1, null, trueDepth

  # ## csSocket ##
  # A similar utility function for adding sockets.
  csSocket: (node, depth, type, dropdown, empty) ->
    @addSocket {
      bounds: @getBounds node
      depth,
      parseContext: type
      dropdown, empty
    }

  # ## csSocketAndMark ##
  # Adds a socket for a node, and recursively @marks it.
  csSocketAndMark: (node, depth, type, indentDepth, dropdown, empty) ->
    socket = @csSocket node, depth, type, dropdown, empty
    @mark node, depth + 1, null, indentDepth
    return socket

  # ## wrapSemicolonLine ##
  # Wrap a single line in a block
  # for semicolons.
  wrapSemicolonLine: (firstBounds, lastBounds, expressions, depth) ->
    surroundingBounds = {
      start: firstBounds.start
      end: lastBounds.end
    }
    @addBlock {
      bounds: surroundingBounds
      depth: depth + 1
      parseContext: 'program'
      nodeContext: new parser.PreNodeContext('semicolon', 0, 0), # TODO Determine parenthesis wrapping etc. for more rigorous paren-wrapping mechanics
      color: @opts.categories['command'].color
      shape: ANY_DROP
    }

    # Add sockets for each expression
    for child in expressions
      @csSocket child, depth + 2, 'semicolon'

  # ## wrapSemicolons ##
  # If there are mutliple expressions we have on the same line,
  # add a semicolon block around them.
  wrapSemicolons: (expressions, depth) ->
    # We will keep track of the first and last
    # nodes on the current line, and their bounds.
    firstNode = lastNode =
      firstBounds = lastBounds = null

    # We will also keep track of the nodes
    # that are on this line, so that
    # we can surround them in sockets
    # in the future.
    nodesOnCurrentLine = []

    for expr in expressions
      # Get the bounds for this expression
      bounds = @getBounds expr

      # If we are on the same line as the last expression, update
      # lastNode to reflect.
      if bounds.start.line is firstBounds?.end.line
        lastNode = expr; lastBounds = bounds
        nodesOnCurrentLine.push expr

      # Otherwise, we are on a new line.
      # See if the previous line needed a semicolon wrapper

      # If there were at least two blocks on the previous line,
      # they do need a semicolon wrapper.
      else
        if lastNode?
          @wrapSemicolonLine firstBounds, lastBounds, nodesOnCurrentLine, depth

        # Regardless of whether or not we added semicolons on the last line,
        # clear the records to make way for the new line.
        firstNode = expr; lastNode = null
        firstBounds = @getBounds expr; lastBounds = null
        nodesOnCurrentLine = [expr]

    # Wrap up the last line if necessary.
    if lastNode?
      @wrapSemicolonLine firstBounds, lastBounds, nodesOnCurrentLine, depth

# ERROR RECOVERY
# =============

fixCoffeeScriptError = (lines, e) ->
  if lines.length is 1 and /^['"]|['"]$/.test lines[0]
    return fixQuotedString lines
  if /unexpected\s*(?:newline|if|for|while|switch|unless|end of input)/.test(
      e.message) and /^\s*(?:if|for|while|unless)\s+\S+/.test(
      lines[e.location.first_line])
    return addEmptyBackTickLineAfter lines, e.location.first_line
  if /unexpected/.test(e.message)
    return backTickLine lines, e.location.first_line

  if /missing "/.test(e.message) and '"' in lines[e.location.first_line]
    return backTickLine lines, e.location.first_line

  # Try to find the line with an opening unmatched thing
  if /unmatched|missing \)/.test(e.message)
    unmatchedline = findUnmatchedLine lines, e.location.first_line
    if unmatchedline isnt null
      return backTickLine lines, unmatchedline

  return null

findUnmatchedLine = (lines, above) ->
  # Not done yet
  return null

backTickLine = (lines, n) ->
  if n < 0 or n >= lines.length
    return false
  # This strategy fails if the line is already backticked or is empty.
  if /`/.test(lines[n]) or /^\s*$/.test(lines[n])
    return false
  lines[n] = lines[n].replace /^(\s*)(\S.*\S|\S)(\s*)$/, '$1`#$2`$3'
  return true

addEmptyBackTickLineAfter = (lines, n) ->
  if n < 0 or n >= lines.length
    return false
  # Refuse to add another empty backtick line if there is one already
  if n + 1 < lines.length and /^\s*``$/.test lines[n + 1]
    return false
  leading = /^\s*/.exec lines[n]
  # If we are all spaces then fail.
  if not leading or leading[0].length >= lines[n].length
    return false
  lines.splice n + 1, 0, leading[0] + '  ``'

CoffeeScriptParser.empty = "``"
CoffeeScriptParser.emptyIndent = "``"
CoffeeScriptParser.startComment = '###'
CoffeeScriptParser.endComment = '###'
CoffeeScriptParser.startSingleLineComment = '# '

CoffeeScriptParser.drop = (block, context, pred) ->
  if context.parseContext is '__comment__'
    return helper.FORBID

  if context.type is 'socket'
    # TODO forbid-all replacements
    #
    if context.parseContext is 'Lvalue'
      if block.nodeContext.type is 'PropertyAccess'
        return helper.ENCOURAGE
      else
        return helper.FORBID

    else if block.shape in [helper.VALUE_ONLY, helper.MOSTLY_VALUE, helper.ANY_DROP]
      return helper.ENCOURAGE

    else if block.shape is helper.MOSTLY_BLOCK
      return helper.DISCOURAGE

  else if context.type in ['indent', 'document']
    if block.shape in [helper.BLOCK_ONLY, helper.MOSTLY_BLOCK, helper.ANY_DROP] or
        block.type is 'document'
      return helper.ENCOURAGE

    else if block.shape is helper.MOSTLY_VALUE
      return helper.DISCOURAGE

  return helper.DISCOURAGE

CoffeeScriptParser.parens = (leading, trailing, node, context) ->
  # Don't attempt to paren wrap comments
  return if '__comment__' is node.parseContext

  trailing trailing().replace /\s*,\s*$/, ''

  # Remove existing parentheses
  while true
    if leading().match(/^\s*\(/)? and trailing().match(/\)\s*/)?
      leading leading().replace(/^\s*\(\s*/, '')
      trailing trailing().replace(/\s*\)\s*$/, '')
    else
      break
  unless context is null or context.type isnt 'socket' or
      getPrecedence(context.parseContext) < getPrecedence(node.nodeContext.type)
    console.log 'adding as the result of', context.parseContext, node.nodeContext.type, getPrecedence(context.parseContext), getPrecedence(node.nodeContext.type)
    leading '(' + leading()
    trailing trailing() + ')'

  return

CoffeeScriptParser.getDefaultSelectionRange = (string) ->
  start = 0; end = string.length
  if string.length > 1 and string[0] is string[string.length - 1] and string[0] in ['"', '\'', '/']
    start += 1; end -= 1
    if string.length > 5 and string[0..2] is string[-3..-1] and string[0..2] in ['"""', '\'\'\'', '///']
      start += 2; end -= 2
  return {start, end}

CoffeeScriptParser.stringFixer = (string) ->
  if /^['"]|['"]$/.test string
    return fixQuotedString [string]
  else
    return string

module.exports = parser.wrapParser CoffeeScriptParser
