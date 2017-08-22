module ElmLang exposing
  ( Exp(..)
  , Term
  , term_
  )

import Position exposing (dummyPosition)
import Whitespace exposing (dummyWhitespace)
import Range exposing (Ranged)
import Padding exposing (Padded)

-- Expressions

-- Helpful: http://elm-lang.org/docs/syntax

type Exp
  = EBool
      { bool : Bool
      }
  | EInt
      { int : Int
      }
  | EFloat
      { float : Float
      }
  | EChar
      { char : Char
      }
  | EString
      { string : String
      }
  | EMultiLineString
      { string : String
      }
  | EList
      { members : List Term
      }
  | EConditional
      { condition : Term
      , trueBranch : Term
      , falseBranch : Term
      }

-- EIds

type alias EId =
  Int

dummyEId : EId
dummyEId =
  -1

-- Terms

type alias Term =
  Ranged
    ( Padded
        { exp : Exp
        , eid : EId
        }
    )

term_ : Exp -> Term
term_ exp =
  { start = dummyPosition
  , end = dummyPosition
  , before = dummyWhitespace
  , after = dummyWhitespace
  , eid = dummyEId
  , exp = exp
  }
