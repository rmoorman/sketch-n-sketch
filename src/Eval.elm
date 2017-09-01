module Eval exposing (run, doEval, parseAndRun, parseAndRun_, evalDelta, initEnv)

import Debug
import Dict
import String

import Lang exposing (..)
import LangUnparser exposing (unparse, unparsePat, unparseWithIds)
import FastParser exposing (parseE, prelude)
import Types
import Utils

------------------------------------------------------------------------------
-- Big-Step Operational Semantics

match : (Pat, Val) -> Maybe Env
match (p,v) = case (p.val.p__, v.v_) of
  (PVar _ x _, _) -> Just [(x,v)]
  (PAs _ x _ innerPat, _) ->
    case match (innerPat, v) of
      Just env -> Just ((x,v)::env)
      Nothing -> Nothing
  (PList _ ps _ Nothing _, VList vs) ->
    Utils.bindMaybe matchList (Utils.maybeZip ps vs)
  (PList _ ps _ (Just rest) _, VList vs) ->
    let (n,m) = (List.length ps, List.length vs) in
    if n > m then Nothing
    else
      let (vs1,vs2) = Utils.split n vs in
      let vRest =
        { v_ = VList vs2
        , lazyVal = LazyVal (lazyValEnv v.lazyVal) (eApp (eVar0 "drop") [lazyValExp v.lazyVal, eConstDummyLoc (toFloat n)])
        , parents = []
        }
      in
      cons (rest, vRest) (matchList (Utils.zip ps vs1))
        -- dummy Provenance, since VList itself doesn't matter
  (PList _ _ _ _ _, _) -> Nothing
  (PConst _ n, VConst _ (n_,_)) -> if n == n_ then Just [] else Nothing
  (PBase _ bv, VBase bv_) -> if (eBaseToVBase bv) == bv_ then Just [] else Nothing
  _ -> Debug.crash <| "Little evaluator bug: Eval.match " ++ (toString p.val.p__) ++ " vs " ++ (toString v.v_)


matchList : List (Pat, Val) -> Maybe Env
matchList pvs =
  List.foldl (\pv acc ->
    case (acc, match pv) of
      (Just old, Just new) -> Just (new ++ old)
      _                    -> Nothing
  ) (Just []) pvs


cons : (Pat, Val) -> Maybe Env -> Maybe Env
cons pv menv =
  case (menv, match pv) of
    (Just env, Just env_) -> Just (env_ ++ env)
    _                     -> Nothing


lookupVar env bt x pos =
  case Utils.maybeFind x env of
    Just v  -> Ok v
    Nothing -> errorWithBacktrace bt <| strPos pos ++ " variable not found: " ++ x ++ "\nVariables in scope: " ++ (String.join " " <| List.map Tuple.first env)


mkCap mcap l =
  let s =
    case (mcap, l) of
      (Just cap, _)       -> cap.val
      (Nothing, (_,_,"")) -> strLoc l
      (Nothing, (_,_,x))  -> x
  in
  s ++ ": "



initEnvRes = Result.map Tuple.second <| (eval [] [] prelude)
initEnv = Utils.fromOk "Eval.initEnv" <| initEnvRes

run : Exp -> Result String (Val, Widgets)
run e =
  doEval initEnv e |> Result.map Tuple.first

doEval : Env -> Exp -> Result String ((Val, Widgets), Env)
doEval initEnv e =
  eval initEnv [] e
  |> Result.map (\((val, widgets), env) -> ((val, postProcessWidgets widgets), env))


-- eval propagates output environment in order to extract
-- initial environment from prelude

-- eval inserts dummyPos during evaluation

eval_ : Env -> Backtrace -> Exp -> Result String (Val, Widgets)
eval_ env bt e = Result.map Tuple.first <| eval env bt e


eval : Env -> Backtrace -> Exp -> Result String ((Val, Widgets), Env)
eval env bt e =

  let thisLazyVal = LazyVal env e in

  -- Deeply tag value with this lazyVal to say value flowed through here.
  let addParent v =
    if FastParser.isPreludeEId e.val.eid then
      v
    else
      let newV_ =
        case v.v_ of
          VConst _ _       -> v.v_
          VBase _          -> v.v_
          VClosure _ _ _ _ -> v.v_
          VList vals       -> VList (List.map addParent vals)
          VDict dict       -> VDict (Dict.map (\_ val -> addParent val) dict)
      in
      { v | v_ = newV_, parents = thisLazyVal::v.parents }
  in

  -- Only use ret or retBoth for new values (i.e. not var lookups): they do not preserve parents
  let retBoth (v_, ws) = ((addParent <| Val v_ thisLazyVal [], ws), env) in
  let ret v_           = retBoth (v_, []) in

  let retV v                             = ((addParent { v | lazyVal = thisLazyVal }, []), env) in
  let retVBoth (v, ws)                   = ((addParent { v | lazyVal = thisLazyVal }, ws), env) in
  let addParentToRet ((v,ws),envOut)     = ((addParent v, ws), envOut) in
  let addProvenanceToRet ((v,ws),envOut) = ((addParent { v | lazyVal = thisLazyVal }, ws), envOut) in
  let addWidgets ws1 ((v1,ws2),env1)     = ((v1, ws1 ++ ws2), env1) in


  let bt_ =
    if e.start.line >= 1
    then e::bt
    else bt
  in

  case e.val.e__ of

  EConst _ i l wd ->
    let v_ = VConst Nothing (i, TrLoc l) in
    case wd.val of
      NoWidgetDecl         -> Ok <| ret v_
      IntSlider a _ b mcap hidden ->
        Ok <| retBoth (v_, [WIntSlider a.val b.val (mkCap mcap l) (floor i) l hidden])
      NumSlider a _ b mcap hidden ->
        Ok <| retBoth (v_, [WNumSlider a.val b.val (mkCap mcap l) i l hidden])

  EBase _ v      -> Ok <| ret <| VBase (eBaseToVBase v)
  EVar _ x       -> Result.map retV <| lookupVar env (e::bt) x e.start
  EFun _ [p] e _ -> Ok <| ret <| VClosure Nothing p e env
  EOp _ op es _  -> Result.map (\res -> addProvenanceToRet (res, env)) <| evalOp env e (e::bt) op es

  EList _ es _ m _ ->
    case Utils.projOk <| List.map (eval_ env bt_) es of
      Err s -> Err s
      Ok results ->
        let (vs,wss) = List.unzip results in
        let ws = List.concat wss in
        case m of
          Nothing   -> Ok <| retBoth (VList vs, ws)
          Just rest ->
            case eval_ env bt_ rest of
              Err s -> Err s
              Ok (vRest, ws_) ->
                case vRest.v_ of
                  VList vs_ -> Ok <| retBoth (VList (vs ++ vs_), ws ++ ws_)
                  _         -> errorWithBacktrace (e::bt) <| strPos rest.start ++ " rest expression not a list."

  EIf _ e1 e2 e3 _ ->
    case eval_ env bt e1 of
      Err s -> Err s
      Ok (v1,ws1) ->
        case v1.v_ of
          VBase (VBool True)  -> Result.map (addParentToRet << addWidgets ws1) <| eval env bt e2
          VBase (VBool False) -> Result.map (addParentToRet << addWidgets ws1) <| eval env bt e3
          _                   -> errorWithBacktrace (e::bt) <| strPos e1.start ++ " if-exp expected a Bool but got something else."

  ECase _ e1 bs _ ->
    case eval_ env (e::bt) e1 of
      Err s -> Err s
      Ok (v1,ws1) ->
        case evalBranches env (e::bt) v1 bs of
          Ok (Just (v2,ws2)) -> Ok <| retVBoth (v2, ws1 ++ ws2)
          Err s              -> Err s
          _                  -> errorWithBacktrace (e::bt) <| strPos e1.start ++ " non-exhaustive case statement"

  ETypeCase _ e1 tbranches _ ->
    case eval_ env (e::bt) e1 of
      Err s -> Err s
      Ok (v1,ws1) ->
        case evalTBranches env (e::bt) v1 tbranches of
          Ok (Just (v2,ws2)) -> Ok <| retVBoth (v2, ws1 ++ ws2)
          Err s              -> Err s
          _                  -> errorWithBacktrace (e::bt) <| strPos e1.start ++ " non-exhaustive typecase statement"

  EApp _ e1 [e2] _ ->
    case eval_ env bt_ e1 of
      Err s       -> Err s
      Ok (v1,ws1) ->
        case eval_ env bt_ e2 of
          Err s       -> Err s
          Ok (v2,ws2) ->
            let ws = ws1 ++ ws2 in
            case v1.v_ of
              VClosure Nothing p eBody env_ ->
                case cons (p, v2) (Just env_) of
                  Just env__ -> Result.map (addProvenanceToRet << addWidgets ws) <| eval env__ bt_ eBody -- TODO add eid to vTrace
                  _          -> errorWithBacktrace (e::bt) <| strPos e1.start ++ "bad environment"
              VClosure (Just f) p eBody env_ ->
                case cons (pVar f, v1) (cons (p, v2) (Just env_)) of
                  Just env__ -> Result.map (addProvenanceToRet << addWidgets ws) <| eval env__ bt_ eBody -- TODO add eid to vTrace
                  _          -> errorWithBacktrace (e::bt) <| strPos e1.start ++ "bad environment"
              _ ->
                errorWithBacktrace (e::bt) <| strPos e1.start ++ " not a function"


  ELet _ _ False p e1 e2 _ ->
    case eval_ env bt_ e1 of
      Err s       -> Err s
      Ok (v1,ws1) ->
        case cons (p, v1) (Just env) of
          Just env_ ->
            Result.map (addProvenanceToRet << addWidgets ws1) <| eval env_ bt_ e2

          Nothing   ->
            errorWithBacktrace (e::bt) <| strPos e.start ++ " could not match pattern " ++ (unparsePat >> Utils.squish) p ++ " with " ++ strVal v1


  ELet _ _ True p e1 e2 _ ->
    case eval_ env bt_ e1 of
      Err s       -> Err s
      Ok (v1,ws1) ->
        case (p.val.p__, v1.v_) of
          (PVar _ fname _, VClosure Nothing x body env_) ->
            let _   = Utils.assert "eval letrec" (env == env_) in
            let v1Named = { v1 | v_ = VClosure (Just fname) x body env } in
            case cons (pVar fname, v1Named) (Just env) of
              Just env_ -> Result.map (addProvenanceToRet << addWidgets ws1) <| eval env_ bt_ e2
              _         -> errorWithBacktrace (e::bt) <| strPos e.start ++ "bad ELet"
          (PList _ _ _ _ _, _) ->
            errorWithBacktrace (e::bt) <|
              strPos e1.start ++
              """mutually recursive functions (i.e. letrec [...] [...] e) \
                 not yet implemented"""
               -- Implementation also requires modifications to LangSimplify.simply
               -- so that clean up doesn't prune the funtions.
          _ ->
            errorWithBacktrace (e::bt) <| strPos e.start ++ "bad ELet"

  EColonType _ e1 _ t1 _ ->
    case t1.val of
      -- using (e : Point) as a "point widget annotation"
      TNamed _ a ->
        if String.trim a /= "Point" then eval env bt e1
        else
          eval env bt e1 |> Result.map (\result ->
            let ((v,ws),env_) = result in
            case v.v_ of
              VList [v1, v2] ->
                case (v1.v_, v2.v_) of
                  (VConst _ nt1, VConst _ nt2) ->
                    let vNew = {v | v_ = VList [{v1 | v_ = VConst (Just (X, nt2, v2.lazyVal)) nt1}, {v2 | v_ = VConst (Just (Y, nt1, v1.lazyVal)) nt2}]} in
                    addProvenanceToRet ((vNew, ws ++ [WPoint nt1 v1.lazyVal nt2 v2.lazyVal]), env_)
                  _ ->
                    addProvenanceToRet result
              _ ->
                addProvenanceToRet result
            )
      _ ->
        Result.map addProvenanceToRet <| eval env bt e1

  EComment _ _ e1       -> eval env bt e1
  EOption _ _ _ _ e1    -> eval env bt e1
  ETyp _ _ _ e1 _       -> eval env bt e1
  -- EColonType _ e1 _ _ _ -> eval env bt e1
  ETypeAlias _ _ _ e1 _ -> eval env bt e1

  -- abstract syntactic sugar

  EFun _ ps e1 _           -> Result.map addProvenanceToRet <| eval env bt_ (desugarEFun ps e1)
  EApp _ e1 [] _           -> errorWithBacktrace (e::bt) <| strPos e1.start ++ " application with no arguments"
  EApp _ e1 es _           -> Result.map addProvenanceToRet <| eval env bt_ (desugarEApp e1 es)


evalOp env e bt opWithInfo es =
  let (op,opStart) = (opWithInfo.val, opWithInfo.start) in
  let argsEvaledRes = List.map (eval_ env bt) es |> Utils.projOk in
  case argsEvaledRes of
    Err s -> Err s
    Ok argsEvaled ->
      let (vs,wss) = List.unzip argsEvaled in
      let error () =
        errorWithBacktrace bt
          <| "Bad arguments to " ++ strOp op ++ " operator " ++ strPos opStart
          ++ ":\n" ++ Utils.lines (Utils.zip vs es |> List.map (\(v,e) -> (strVal v) ++ " from " ++ (unparse e)))
      in
      let emptyProvenance val_   = Val val_ (LazyVal env (eTuple0 [])) [] in
      let emptyProvenanceOk val_ = Ok (emptyProvenance val_) in
      let nullaryOp args retVal =
        case args of
          [] -> emptyProvenanceOk retVal
          _  -> error ()
      in
      let unaryMathOp op args =
        case args of
          [VConst _ (n,t)] -> VConst Nothing (evalDelta bt op [n], TrOp op [t]) |> emptyProvenanceOk
          _                -> error ()
      in
      let binMathOp op args =
        case args of
          [VConst maybeAxisAndOtherDim1 (i,it), VConst maybeAxisAndOtherDim2 (j,jt)] ->
            let maybeAxisAndOtherDim =
              case (op, maybeAxisAndOtherDim1, maybeAxisAndOtherDim2) of
                (Plus, Just axisAndOtherDim, Nothing)  -> Just axisAndOtherDim
                (Plus, Nothing, Just axisAndOtherDim)  -> Just axisAndOtherDim
                (Minus, Just axisAndOtherDim, Nothing) -> Just axisAndOtherDim
                _                                      -> Nothing
            in
            VConst maybeAxisAndOtherDim (evalDelta bt op [i,j], TrOp op [it,jt]) |> emptyProvenanceOk
          _  ->
            error ()
      in
      let args = List.map .v_ vs in
      let newValRes =
        case op of
          Plus    -> case args of
            [VBase (VString s1), VBase (VString s2)] -> VBase (VString (s1 ++ s2)) |> emptyProvenanceOk
            _                                        -> binMathOp op args
          Minus     -> binMathOp op args
          Mult      -> binMathOp op args
          Div       -> binMathOp op args
          Mod       -> binMathOp op args
          Pow       -> binMathOp op args
          ArcTan2   -> binMathOp op args
          Lt        -> case args of
            [VConst _ (i,it), VConst _ (j,jt)] -> VBase (VBool (i < j)) |> emptyProvenanceOk
            _                                  -> error ()
          Eq        -> case args of
            [VConst _ (i,it), VConst _ (j,jt)]       -> VBase (VBool (i == j)) |> emptyProvenanceOk
            [VBase (VString s1), VBase (VString s2)] -> VBase (VBool (s1 == s2)) |> emptyProvenanceOk
            [_, _]                                   -> VBase (VBool False) |> emptyProvenanceOk -- polymorphic inequality, added for Prelude.addExtras
            _                                        -> error ()
          Pi         -> nullaryOp args (VConst Nothing (pi, TrOp op []))
          DictEmpty  -> nullaryOp args (VDict Dict.empty)
          DictInsert -> case vs of
            [vkey, val, {v_}] -> case v_ of
              VDict d -> valToDictKey bt vkey.v_ |> Result.map (\dkey -> VDict (Dict.insert dkey val d) |> emptyProvenance)
              _       -> error()
            _                 -> error ()
          DictGet    -> case args of
            [key, VDict d] -> valToDictKey bt key |> Result.map (\dkey -> Utils.getWithDefault dkey (VBase VNull |> emptyProvenance) d)
            _              -> error ()
          DictRemove -> case args of
            [key, VDict d] -> valToDictKey bt key |> Result.map (\dkey -> VDict (Dict.remove dkey d) |> emptyProvenance)
            _              -> error ()
          Cos        -> unaryMathOp op args
          Sin        -> unaryMathOp op args
          ArcCos     -> unaryMathOp op args
          ArcSin     -> unaryMathOp op args
          Floor      -> unaryMathOp op args
          Ceil       -> unaryMathOp op args
          Round      -> unaryMathOp op args
          Sqrt       -> unaryMathOp op args
          Explode    -> case args of
            [VBase (VString s)] ->
              String.toList s
              |> List.map String.fromChar
              |> Utils.mapi0
                  (\(i, charStr) ->
                    { v_ = VBase (VString charStr)
                    , lazyVal = LazyVal env (eApp (eVar0 "nth") [eOp Explode es, eConstDummyLoc (toFloat i)])
                    , parents = []
                    }
                  )
              |> VList
              |> emptyProvenanceOk
            _                   -> error ()
          DebugLog   -> case vs of
            [v] -> let _ = Debug.log (strVal v) "" in Ok v
            _   -> error ()
          NoWidgets  -> case vs of
            [v] -> Ok v -- Widgets removed  below.
            _   -> error ()
          ToStr      -> case vs of
            [val] -> VBase (VString (strVal val)) |> emptyProvenanceOk
            _     -> error ()
      in
      let newWidgets =
        case (op, args) of
          (Plus, [VConst (Just (axis, otherDimNumTr, otherDirLazyVal)) numTr, VConst Nothing amountNumTr]) ->
            let (baseXNumTr, baseYNumTr, endXLazyVal, endYLazyVal) =
              if axis == X
              then (numTr, otherDimNumTr, LazyVal env e, otherDirLazyVal)
              else (otherDimNumTr, numTr, otherDirLazyVal, LazyVal env e)
            in
            [WOffset1D baseXNumTr baseYNumTr axis Positive amountNumTr endXLazyVal endYLazyVal]
          (Plus, [VConst Nothing amountNumTr, VConst (Just (axis, otherDimNumTr, otherDirLazyVal)) numTr]) ->
            let (baseXNumTr, baseYNumTr, endXLazyVal, endYLazyVal) =
              if axis == X
              then (numTr, otherDimNumTr, LazyVal env e, otherDirLazyVal)
              else (otherDimNumTr, numTr, otherDirLazyVal, LazyVal env e)
            in
            [WOffset1D baseXNumTr baseYNumTr axis Positive amountNumTr endXLazyVal endYLazyVal]
          (Minus, [VConst (Just (axis, otherDimNumTr, otherDirLazyVal)) numTr, VConst Nothing amountNumTr]) ->
            let (baseXNumTr, baseYNumTr, endXLazyVal, endYLazyVal) =
              if axis == X
              then (numTr, otherDimNumTr, LazyVal env e, otherDirLazyVal)
              else (otherDimNumTr, numTr, otherDirLazyVal, LazyVal env e)
            in
            [WOffset1D baseXNumTr baseYNumTr axis Negative amountNumTr endXLazyVal endYLazyVal]
          _ -> []
      in
      let widgets =
        case op of
          NoWidgets -> []
          _         -> List.concat wss ++ newWidgets
      in
      newValRes
      |> Result.map (\newVal -> (newVal, widgets))


-- Returns Ok Nothing if no branch matches
-- Returns Ok (Just results) if branch matches and no execution errors
-- Returns Err s if execution error
evalBranches env bt v bs =
  List.foldl (\(Branch_ _ pat exp _) acc ->
    case (acc, cons (pat,v) (Just env)) of
      (Ok (Just done), _)     -> acc
      (Ok Nothing, Just env_) -> eval_ env_ bt exp |> Result.map Just
      (Err s, _)              -> acc
      _                       -> Ok Nothing

  ) (Ok Nothing) (List.map .val bs)


-- Returns Ok Nothing if no branch matches
-- Returns Ok (Just results) if branch matches and no execution errors
-- Returns Err s if execution error
evalTBranches env bt val tbranches =
  List.foldl (\(TBranch_ _ tipe exp _) acc ->
    case acc of
      Ok (Just done) ->
        acc

      Ok Nothing ->
        if Types.valIsType val tipe then
          eval_ env bt exp |> Result.map Just
        else
          acc

      Err s ->
        acc
  ) (Ok Nothing) (List.map .val tbranches)


evalDelta bt op is =
  case (op, is) of

    (Plus,    [i,j]) -> (+) i j
    (Minus,   [i,j]) -> (-) i j
    (Mult,    [i,j]) -> (*) i j
    (Div,     [i,j]) -> (/) i j
    (Pow,     [i,j]) -> (^) i j
    (Mod,     [i,j]) -> toFloat <| (%) (floor i) (floor j)
                         -- might want an error/warning for non-int
    (ArcTan2, [i,j]) -> atan2 i j

    (Cos,     [n])   -> cos n
    (Sin,     [n])   -> sin n
    (ArcCos,  [n])   -> acos n
    (ArcSin,  [n])   -> asin n
    (Floor,   [n])   -> toFloat <| floor n
    (Ceil,    [n])   -> toFloat <| ceiling n
    (Round,   [n])   -> toFloat <| round n
    (Sqrt,    [n])   -> sqrt n

    (Pi,      [])    -> pi

    _                -> crashWithBacktrace bt <| "Little evaluator bug: Eval.evalDelta " ++ strOp op


eBaseToVBase eBaseVal =
  case eBaseVal of
    EBool b     -> VBool b
    EString _ b -> VString b
    ENull       -> VNull


valToDictKey : Backtrace -> Val_ -> Result String (String, String)
valToDictKey bt val_ =
  case val_ of
    VConst _ (n, tr)  -> Ok <| (toString n, "num")
    VBase (VBool b)   -> Ok <| (toString b, "bool")
    VBase (VString s) -> Ok <| (toString s, "string")
    VBase VNull       -> Ok <| ("", "null")
    VList vals        ->
      vals
      |> List.map ((valToDictKey bt) << .v_)
      |> Utils.projOk
      |> Result.map (\keyStrings -> (toString keyStrings, "list"))
    _                 -> errorWithBacktrace bt <| "Cannot use " ++ (strVal { v_ = val_, lazyVal = dummyLazyVal, parents = [] }) ++ " in a key to a dictionary."


postProcessWidgets widgets =
  let dedupedWidgets = Utils.dedupByEquality widgets in
  -- partition so that hidden and point sliders don't affect indexing
  -- (and, thus, positioning) of range sliders
  --
  let (rangeWidgets, pointWidgets) =
    dedupedWidgets |>
      List.partition (\widget ->
        case widget of
          WIntSlider _ _ _ _ _ False -> True
          WNumSlider _ _ _ _ _ False -> True
          WIntSlider _ _ _ _ _ True  -> False
          WNumSlider _ _ _ _ _ True  -> False
          WPoint _ _ _ _             -> False
          WOffset1D _ _ _ _ _ _ _    -> False
      )
  in
  rangeWidgets ++ pointWidgets

parseAndRun : String -> String
parseAndRun = strVal << Tuple.first << Utils.fromOk_ << run << Utils.fromOkay "parseAndRun" << parseE

parseAndRun_ = strVal_ True << Tuple.first << Utils.fromOk_ << run << Utils.fromOkay "parseAndRun_" << parseE

btString : Backtrace -> String
btString bt =
  case bt of
    [] -> ""
    mostRecentExp::others ->
      let singleLineExpStrs =
        others
        |> List.map (Utils.head_ << String.lines << String.trimLeft << unparse)
        |> List.reverse
        |> String.join "\n"
      in
      singleLineExpStrs ++ "\n" ++ (unparse mostRecentExp)


errorWithBacktrace bt message =
  errorMsg <| (btString bt) ++ "\n" ++ message

crashWithBacktrace bt message =
  crashWithMsg <| (btString bt) ++ "\n" ++ message
