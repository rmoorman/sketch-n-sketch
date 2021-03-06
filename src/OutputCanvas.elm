port module OutputCanvas exposing
  ( initialize
  , resetScroll
  , receiveOutputCanvasState
  , receiveValueUpdate
  , maybeAutoSync
  , enableAutoSync
  , setAutoSyncDelay
  , setPreviewMode
  , setDomShapeAttribute
  , setDiffTimer
  , DiffTimer
  , clearPreviewDiff
  , setCaretPosition
  , stopDomListener
  , startDomListener
  , setExampleByName
  )

import Model exposing (Model, OutputCanvasInfo)
import Json.Decode as JSDecode

--------------------------------------------------------------------------------
-- Ports

-- Outgoing

port outputCanvasCmd : OutputCanvasCmd -> Cmd msg

type alias OutputCanvasCmd =
  { message : String
  }

type alias DiffTimer = { delay: Int, activate: Bool}

initialize  = sendCmd "initialize"
resetScroll = sendCmd "resetScroll"
stopDomListener = sendCmd "stopDomListener"
startDomListener = sendCmd "startDomListener"

sendCmd message =
  outputCanvasCmd <|
    { message = message
    }

port enableAutoSync: Bool -> Cmd msg

port setAutoSyncDelay : Int -> Cmd msg

port setPreviewMode: Bool -> Cmd msg

port setDomShapeAttribute : {nodeId:Int, attrName:String, attrValue:String} -> Cmd msg

port setDiffTimer: DiffTimer-> Cmd msg

port setCaretPosition: Int -> Cmd msg

-- Incoming

port receiveOutputCanvasState : (OutputCanvasInfo -> msg) -> Sub msg

port receiveValueUpdate : ((Int, List Int, JSDecode.Value)-> msg) -> Sub msg

port maybeAutoSync : (Int -> msg) -> Sub msg

port clearPreviewDiff : (Int -> msg) -> Sub msg

port setExampleByName: (String -> msg) -> Sub msg