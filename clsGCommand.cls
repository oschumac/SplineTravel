VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
  Persistable = 0  'NotPersistable
  DataBindingBehavior = 0  'vbNone
  DataSourceBehavior  = 0  'vbNone
  MTSTransactionMode  = 0  'NotAnMTSObject
END
Attribute VB_Name = "clsGCommand"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
Option Explicit

Public strLine As String

Private stateBefore As typCurrentState
Private stateAfter As typCurrentState
Public touched As Boolean
Private myCmdType As eGCommand
Private myMove As clsGMove

Private refPrevCommand As clsGCommand
Private refNextCommand As clsGCommand
Public inChain As clsChain 'dumb member, to be managed by the chain itself

Public Enum eGCommand
'low byte = letter:
'G = &H47
'M = &H4D
'high byte = number after letter
  egcEmpty = 0
  G0_quickMove = &H47&
  G1_controlledMove = &H147&
  G4_dwell = &H447&
  G21_setUnitMm = &H1547&
  M82_absoluteE = &H524D&
  M83_relativeE = &H534D&
  G90_absolutePos = &H5A47&
  G91_relativePos = &H5B47&
  G92_overridePos = &H5C47&
End Enum

Private Type typLetVal 'letter + value, argument of g command
  'letter as byte = index of array
  value As Double
  specified As Boolean
End Type

Dim arguments(65 To 90) As typLetVal '65 to 90 = A to Z

'recompute states: update stateBefore from previous command;
'reparse arguments of a command and compute the new state.
'if preserveDeltaE is specified, current extrusion length as
'derived from current difference in states, is preserved
'(unless the command is G92)
Public Sub RecomputeStates(Optional ByVal preserveDeltaE = False)

'save current deltaE, we'll need it if preserveDeltaE = true
Dim oldDeltaE As Double
oldDeltaE = stateAfter.Epos - stateBefore.Epos

If Not (refPrevCommand Is Nothing) Then
  stateBefore = refPrevCommand.CompleteStateAfter
End If

'reset stateAfter to match stateBefore, then apply changes.
stateAfter = stateBefore

'these values are handled in a command-independent way, assume they are global-persistent
Dim arg As typLetVal
arg = arguments(Asc("X"))
If arg.specified Then
  If stateBefore.MoveRelative Then
    stateAfter.pos.X = stateAfter.pos.X + arg.value
  Else
    stateAfter.pos.X = arg.value
  End If
End If
arg = arguments(Asc("Y"))
If arg.specified Then
  If stateBefore.MoveRelative Then
    stateAfter.pos.Y = stateAfter.pos.Y + arg.value
  Else
    stateAfter.pos.Y = arg.value
  End If
End If
arg = arguments(Asc("Z"))
If arg.specified Then
  If stateBefore.MoveRelative Then
    stateAfter.pos.Z = stateAfter.pos.Z + arg.value
  Else
    stateAfter.pos.Z = arg.value
  End If
End If

arg = arguments(Asc("E"))
If arg.specified Then
  If stateBefore.ExtrusionRelative Then
    stateAfter.Epos = stateBefore.Epos + arg.value
  Else
    stateAfter.Epos = arg.value
  End If
  If preserveDeltaE Then
    stateAfter.Epos = stateBefore.Epos + oldDeltaE
  End If
End If

arg = arguments(Asc("F"))
If arg.specified Then
  stateAfter.Speed = arg.value / 60 'convert to mm/s
End If

Select Case myCmdType
  Case eGCommand.G90_absolutePos
    stateAfter.MoveRelative = False
  Case eGCommand.G91_relativePos
    stateAfter.MoveRelative = True
  Case eGCommand.M82_absoluteE
    stateAfter.ExtrusionRelative = False
  Case eGCommand.M83_relativeE
    stateAfter.ExtrusionRelative = True
  Case eGCommand.G92_overridePos
    If arguments(Asc("E")).specified Then
      stateAfter.Epos = arguments(Asc("E")).value
    End If
    If arguments(Asc("X")).specified Then
      stateAfter.pos.X = arguments(Asc("X")).value
    End If
    If arguments(Asc("Y")).specified Then
      stateAfter.pos.Y = arguments(Asc("Y")).value
    End If
    If arguments(Asc("Z")).specified Then
      stateAfter.pos.Z = arguments(Asc("Z")).value
    End If
End Select
End Sub

Friend Property Get CompleteStateAfter() As typCurrentState
CompleteStateAfter = stateAfter
End Property

Public Sub ParseString(Optional ByVal throwIfInvalid = False)
Erase arguments
myCmdType = 0

On Error GoTo eh

  Dim lineText As String
  lineText = strLine
  
  'get rid of comment
  Dim pos As Long
  pos = InStr(lineText, ";")
  If pos > 0 Then
    lineText = Trim$(Left$(lineText, pos - 1))
  End If
  'get rid of checksum
  pos = InStrRev(lineText, "*")
  If pos > 0 Then
    lineText = Trim$(Left$(lineText, pos - 1))
  End If
  
  If Len(lineText) = 0 Then Exit Sub
  Dim words() As String
  words = Split(lineText, " ")
  Dim iword As Long
  For iword = 0 To UBound(words)
    If Len(words(iword)) > 0 Then 'this check is needed to deal with double spaces
      Dim firstletter As Long
      firstletter = Asc(UCase$(Mid$(words(iword), 1, 1)))
      If firstletter < Asc("A") Or firstletter > Asc("Z") Then
        Throw errInvalidCommand, extraMessage:="first character of a word in a command must be a latin letter; it is """ + Chr$(firstletter) + """"
      End If
      Dim value As Double
      value = val(Mid$(words(iword), 2))
      
      If iword = 0 Then
        myCmdType = CLng(value) * &H100 + firstletter
      Else
        arguments(firstletter).specified = True
        arguments(firstletter).value = value
      End If
    End If
  Next iword
  processArguments
Exit Sub
eh:
If throwIfInvalid Then
  Throw
Else
  Debug.Print "Error parsing G-code line. Line = """ + strLine + """"
  Debug.Print "Error is: " + Err.Description
End If

End Sub

Public Function isEmpty()
isEmpty = (myCmdType = egcEmpty)
End Function

'the command involves moving of head; the move can be constructed
'note that this will be true for speed setting command; checking for this is a todo
Public Function isMove()
isMove = (myCmdType = G0_quickMove) Or (myCmdType = G1_controlledMove)
End Function

Public Sub processArguments()
Select Case myCmdType
  Case eGCommand.G0_quickMove, eGCommand.G1_controlledMove
    constructMove
End Select
End Sub

Private Sub constructMove()
If Not isMove Then
  Set myMove = Nothing
  Exit Sub
End If

If myMove Is Nothing Then
  Set myMove = New clsGMove
End If
myMove.p1.copyFromT stateBefore.pos
myMove.p2.copyFromT stateAfter.pos
myMove.Extrusion = stateAfter.Epos - stateBefore.Epos

If myMove.TravelDist > 1E-100 Then
  myMove.Speed = stateAfter.Speed
ElseIf Abs(myMove.Extrusion) > 1E-100 Then
  myMove.ExtrusionSpeed = stateAfter.Speed
Else
  'move is invalid
  Set myMove = Nothing
End If
End Sub

'to make sure the move is up-to-date, call constructMove before calling this
Public Function getMove() As clsGMove
Set getMove = myMove
End Function

Public Property Get prevCommand() As clsGCommand
Set prevCommand = refPrevCommand
End Property

Public Property Set prevCommand(newVal As clsGCommand)
Set refPrevCommand = newVal
End Property


Public Property Get nextCommand() As clsGCommand
Set nextCommand = refNextCommand
End Property

Public Property Set nextCommand(newVal As clsGCommand)
Set refNextCommand = newVal
End Property

'
'Public Sub DiscardChainBeforeMe()
'Dim cmd As clsGCommand
''disassemble chain preceding this command
'Set cmd = Me.prevCommand
'Do Until cmd Is Nothing
'  Set cmd.nextCommand.prevCommand = Nothing
'  Set cmd.nextCommand = Nothing
'  Set cmd = cmd.prevCommand
'Loop Until cmd Is Nothing
'End Sub
'
'Public Sub DiscardChainAfterMe()
'Dim cmd As clsGCommand
''disassemble chain preceding this command
'Set cmd = Me.nextCommand
'Do Until cmd Is Nothing
'  Set cmd.prevCommand.nextCommand = Nothing
'  Set cmd.prevCommand = Nothing
'  Set cmd = cmd.nextCommand
'Loop
'End Sub