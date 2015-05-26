readFile = (name) ->
  q = new XMLHttpRequest()
  q.open 'GET', name, false
  q.send()
  return q.responseText

require.config
  baseUrl: '../js'
  paths: JSON.parse readFile '../requirejs-paths.json'

require ['droplet'], (droplet) ->

  # Example palette
  window.editor = new droplet.Editor document.getElementById('editor'), {
    # CSV TESTING:
    mode: 'html'
    palette: [
      {
        name: 'Basic'
        color: 'violet'
        blocks: [
        ]
      }
    ]
  }

  # Example program (fizzbuzz)
  examplePrograms = {
    descriptive: '''
      <!DOCTYPE html PUBLIC "-//IETF//DTD HTML 2.0//EN">
      <HTML>
        <HEAD>
          <TITLE>
            A Small Hello
          </TITLE>
        </HEAD>
        <BODY>
          <H1>Hi</H1>
          <P>This is very minimal <b>hello world</b> HTML document.</P>
        </BODY>
      </HTML>

      '''

    empty: ''
  }

  editor.setEditorState false
  editor.aceEditor.getSession().setUseWrapMode true
  editor.aceEditor.getSession().setMode 'ace/mode/html'

  # Initialize to starting text
  startingText = localStorage.getItem 'example'
  editor.setValue startingText or examplePrograms.descriptive

  # Update textarea on ICE editor change
  onChange = ->
    localStorage.setItem 'example', editor.getValue()

  editor.on 'change', onChange

  editor.aceEditor.on 'change', onChange

  # Trigger immediately
  do onChange

  document.getElementById('which_example').addEventListener 'change', ->
    editor.setValue examplePrograms[@value]

  editor.clearUndoStack()

  messageElement = document.getElementById 'message'
  displayMessage = (text) ->
    messageElement.style.display = 'inline'
    messageElement.innerText = text
    setTimeout (->
      messageElement.style.display = 'none'
    ), 2000

  document.getElementById('toggle').addEventListener 'click', ->
    editor.toggleBlocks()
    if $('#palette_dialog').dialog 'isOpen'
      $('#palette_dialog').dialog 'close'
    else
      $("#palette_dialog").dialog 'open'