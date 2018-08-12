module SlowTypeInference exposing (..)

import FastParser
import Syntax
import Lang exposing (..)
import LangTools
import Types
import Utils
import ImpureGoodies

import Dict exposing (Dict)
import Set exposing (Set)


type Constraint
  = EIdIsType EId TypeConstraint
  | PIdIsType PId TypeConstraint
  | PIdIsEId PId EId
  | EIdVar EId Ident
  | PIdVar PId Ident
  | EIdIsEmpty EId String
  | PIdIsEmpty PId String
  | TypeAlias Ident TypeConstraint


-- TypeConstraint ---------------------------------------------------------

type TypeConstraint
  = TCEId EId
  | TCPId PId
  | TCApp TypeConstraint (List TypeConstraint)
  | TCNum
  | TCBool
  | TCString
  | TCNull
  | TCList TypeConstraint
  | TCTuple (List TypeConstraint) (Maybe TypeConstraint)
  | TCPatTuple (List TypeConstraint) (Maybe TypeConstraint)
  | TCArrow (List TypeConstraint)
  | TCUnion (List TypeConstraint)
  | TCNamed Ident
  | TCVar Ident
  | TCForall (List Ident) TypeConstraint
  | TCWildcard


-- childTCs : TypeConstraint -> List TypeConstraint
-- childTCs tc =
--   case tc of
--     TCEId _             -> []
--     TCPId _             -> []
--     TCApp tc1 tcs       -> tc1::tcs
--     TCNum               -> []
--     TCBool              -> []
--     TCString            -> []
--     TCNull              -> []
--     TCList tc1          -> [tc1]
--     TCTuple tcs mtc     -> tcs ++ (mtc |> Maybe.map List.singleton |> Maybe.withDefault [])
--     TCArrow tcs         -> tcs
--     TCUnion tcs         -> tcs
--     TCNamed _           -> []
--     TCVar _             -> []
--     TCForall idents tc1 -> [tc1]
--     TCWildcard          -> []
--
--
-- flattenTCTree : TypeConstraint -> List TypeConstraint
-- flattenTCTree tc =
--   tc :: List.concatMap flattenTCTree (childTCs tc)


-- Bottom up
mapTC : (TypeConstraint -> TypeConstraint) -> TypeConstraint -> TypeConstraint
mapTC f tc =
  let recurse = mapTC f in
  case tc of
    TCEId _             -> f tc
    TCPId _             -> f tc
    TCApp tc1 tcs       -> f <| TCApp (recurse tc1) (List.map recurse tcs)
    TCNum               -> f tc
    TCBool              -> f tc
    TCString            -> f tc
    TCNull              -> f tc
    TCList tc1          -> f <| TCList (recurse tc1)
    TCTuple tcs mtc     -> f <| TCTuple (List.map recurse tcs) (Maybe.map recurse mtc)
    TCPatTuple tcs mtc  -> f <| TCPatTuple (List.map recurse tcs) (Maybe.map recurse mtc)
    TCArrow tcs         -> f <| TCArrow (List.map recurse tcs)
    TCUnion tcs         -> f <| TCUnion (List.map recurse tcs)
    TCNamed _           -> f tc
    TCVar _             -> f tc
    TCForall idents tc1 -> f <| TCForall idents (recurse tc1)
    TCWildcard          -> f tc


typeToTC : Type -> TypeConstraint
typeToTC tipe =
  case tipe.val of
    TNum _                           -> TCNum
    TBool _                          -> TCBool
    TString _                        -> TCString
    TNull _                          -> TCNull
    TList _ tipe _                   -> TCList (typeToTC tipe)
    TDict _ tipe1 tipe2 _            -> TCWildcard -- Dict will be removed shortly
    TTuple _ heads _ maybeRestType _ -> TCPatTuple (List.map typeToTC heads) (Maybe.map typeToTC maybeRestType)
    TArrow _ typeList _              -> TCArrow (List.map typeToTC typeList)
    TUnion _ typeList _              -> TCUnion (List.map typeToTC typeList)
    TNamed _ ident                   -> TCNamed ident
    TVar _ ident                     -> TCVar ident
    TWildcard _                      -> TCWildcard
    TForall _ typeVars tipe1 _       ->
      let idents =
        case typeVars of
          One (_, ident) -> [ident]
          Many _ inner _ -> inner |> List.map (\(_, ident) -> ident)
      in
      TCForall idents (typeToTC tipe1)


-- TypeConstraint2 ---------------------------------------------------------

-- Graph of Dict TC2Id (Set TC2)
-- (Set TC2) represents constraints to unify
-- Fixpoint when, after propagating TC2SameAs, each (Set TC2) is either
--   (a) all TC2SameAs
--   (b) a singleton
--
-- Constraints are propogated by joining connected components (via TC2SameAs) or
-- inserting TC2Unify nodes.
--
-- TC2Unify and TC2App nodes have a "cached" constraint, i.e. the computed result so
-- far. Should only narrow. Thus constraints slowly propogate step-by-step through
-- the graph.
--
-- TC2UnifyOne is an attempt to handle unions. Not always successful.
--

type alias TC2Id    = Int  -- PIds, EIds, and various shared types
type alias TC2Graph = Dict TC2Id (Set TC2)

type TC2
  = TC2SameAs TC2Id      -- Graph edge
  | TC2Empty String      -- Type error
  | TC2Unify TC2Id TC2Id (Maybe TC2) (Maybe TC2) (Maybe TC2) -- Deferred unification; ids to unify, two constraints most recently unified, cached unification (Nothing means not computed yet i.e. Unknown)
  | TC2UnifyOne TC2Id (Maybe TC2) TC2 -- In-place constraint (can be narrowed); Maybe TC2 is most recently left constraint used
  | TC2App TC2Id TC2Id (Maybe TC2) -- Special case of deferred unifcation
  | TC2Num
  | TC2Bool
  | TC2String
  | TC2Null
  -- | TC2List TC2Id
  | TC2Tuple Int (List TC2Id) (Maybe TC2Id) -- Number is maximum size of list seen, using such is slighly less unsound than ignoring such when reconciling with a PatTuple
  | TC2PatTuple (List TC2Id) (Maybe TC2Id)
  | TC2Arrow TC2Id TC2Id -- Binary applications
  | TC2Union (List TC2Id)
  -- Forall should introduce + resolve type vars to a new node
  -- | TC2Var Ident -- TC2Id -- TC2Id is context
  -- | TC2Forall (List Ident) TC2Id
  -- | TC2Wildcard


maxSafeInt : Int
maxSafeInt = 2^31 - 1 -- IEEE doubles can represent ints up to 2^53 - 1, but bitwise ops only work up to 2^31 - 1


nextUnusedId : TC2Graph -> Int
nextUnusedId graph = 1 + (Dict.keys graph |> List.maximum |> Maybe.withDefault 0)


applyTC2IdSubst : Dict TC2Id TC2Id -> TC2 -> TC2
applyTC2IdSubst tc2IdSubst tc2 =
  let apply id = Utils.getWithDefault id id tc2IdSubst in
  case tc2 of
    TC2SameAs id                -> TC2SameAs (apply id)
    TC2Empty _                  -> tc2
    TC2Unify idl idr ml mr mc   -> TC2Unify (apply idl) (apply idr) ml mr mc
    TC2UnifyOne id ml c         -> TC2UnifyOne (apply id) ml c
    TC2App idl idr mc           -> TC2App (apply idl) (apply idr) mc
    TC2Num                      -> tc2
    TC2Bool                     -> tc2
    TC2String                   -> tc2
    TC2Null                     -> tc2
    TC2Tuple n headIds mTailId  -> TC2Tuple n (List.map apply headIds) (Maybe.map apply mTailId)
    TC2PatTuple headIds mTailId -> TC2PatTuple (List.map apply headIds) (Maybe.map apply mTailId)
    TC2Arrow idl idr            -> TC2Arrow (apply idl) (apply idr)
    TC2Union ids                -> TC2Union (List.map apply ids)

tc2ChildIds : TC2 -> List TC2Id
tc2ChildIds tc2 =
  case tc2 of
    TC2SameAs id                -> [id]
    TC2Empty _                  -> []
    TC2Unify idl idr ml mr mc   -> [idl, idr]
    TC2UnifyOne id ml c         -> [id]
    TC2App idl idr mc           -> [idl, idr]
    TC2Num                      -> []
    TC2Bool                     -> []
    TC2String                   -> []
    TC2Null                     -> []
    TC2Tuple n headIds mTailId  -> headIds ++ (mTailId |> Maybe.map List.singleton |> Maybe.withDefault [])
    TC2PatTuple headIds mTailId -> headIds ++ (mTailId |> Maybe.map List.singleton |> Maybe.withDefault [])
    TC2Arrow idl idr            -> [idl, idr]
    TC2Union ids                -> ids


tc2IsASameAs : TC2 -> Bool
tc2IsASameAs tc2 =
  case tc2 of
    TC2SameAs _ -> True
    _           -> False

tc2IsEmpty : TC2 -> Bool
tc2IsEmpty tc2 =
  case tc2 of
    TC2Empty _ -> True
    _          -> False


-- tc2IsUnifyOrUnifyOne : TC2 -> Bool
-- tc2IsUnifyOrUnifyOne tc2 =
--   case tc2 of
--     TC2Unify _ _ _ _ _ -> True
--     TC2UnifyOne _ _ _  -> True
--     _                  -> False
--
--
tc2ToMaybeSameAsId : TC2 -> Maybe TC2Id
tc2ToMaybeSameAsId tc2 =
  case tc2 of
    TC2SameAs tc2Id -> Just tc2Id
    _               -> Nothing


tc2IdToSameAsIds : TC2Id -> TC2Graph -> List TC2Id
tc2IdToSameAsIds tc2Id graph =
  case Dict.get tc2Id graph of
    Just tc2set -> Set.toList tc2set |> List.filterMap tc2ToMaybeSameAsId
    Nothing     -> []


getTC2Constraints : TC2Id -> TC2Graph -> Set TC2
getTC2Constraints tc2id graph =
  Utils.getWithDefault tc2id Set.empty graph


addTC2ToGraph : TC2Id -> TC2 -> TC2Graph -> TC2Graph
addTC2ToGraph = Utils.dictAddToSet


removeTC2FromGraph : TC2Id -> TC2 -> TC2Graph -> TC2Graph
removeTC2FromGraph = Utils.dictRemoveFromSet


addIdsEdgeToGraph : TC2Id -> TC2Id -> TC2Graph -> TC2Graph
addIdsEdgeToGraph id1 id2 graph =
  if id1 == id2 then
    graph
  else
    graph
    |> addTC2ToGraph id1 (TC2SameAs id2)
    |> addTC2ToGraph id2 (TC2SameAs id1)


equivalentIds : TC2Id -> TC2Graph -> Set TC2Id
equivalentIds id graph =
  equivalentIds_ Set.empty [id] graph


equivalentIds_ : Set TC2Id -> List TC2Id -> TC2Graph -> Set TC2Id
equivalentIds_ visited toVisit graph =
  case toVisit of
    []            -> visited
    id::remaining ->
      if Set.member id visited then
        equivalentIds_ visited remaining graph
      else
        let newVisited = Set.insert id visited in
        let newToVisit = tc2IdToSameAsIds id graph ++ remaining in
        equivalentIds_ newVisited newToVisit graph


canonicalId : TC2Id -> TC2Graph -> TC2Id
canonicalId id graph =
  equivalentIds id graph |> Set.toList |> List.minimum |> Maybe.withDefault id


-- 1. Add transitively connected edges to the graph.
-- 2. For each such "component", put all non-SameAs constraints on a single node.
-- "component" converges to a strongly connected component.
propagateGraphConstraints : TC2Graph -> TC2Graph
propagateGraphConstraints graph =
  let (_, newGraph) =
    graph
    |> Dict.foldl
        (\id tc2set (visited, graph) ->
          if Set.member id visited then
            (visited, graph)
          else
            -- Gather a "component".
            -- After several iterations of propagateGraphConstraints this will converge to a connected component.
            let
              equivIdSet = equivalentIds id graph
              equivIds   = Set.toList equivIdSet
              -- Gather all the constraints to unify
              thisComponentConstraints =
                equivIds
                |> List.concatMap (\id -> Utils.getWithDefault id Set.empty graph |> Set.toList)
                |> List.filter (not << tc2IsASameAs)
                |> Set.fromList

              -- Point all nodes to this one
              tc2setPointToThisNode = Set.singleton (TC2SameAs id)
              newGraph = equivIds |> List.foldl (\id graph -> Dict.insert id tc2setPointToThisNode graph) graph

              -- Put all the constraints on this node
              -- As well as pointers to all same nodes
              tc2SameAsSet = equivIds |> List.map TC2SameAs |> Set.fromList
              newGraph2 = Dict.insert id (Set.union thisComponentConstraints tc2SameAsSet) newGraph
            in
            (Set.union equivIdSet visited, newGraph2)
        )
        (Set.empty, graph)
  in
  newGraph


-- Only unifies a pair on a node at a time. Least likely to produce bugs with new nodes appearing.
unifyImmediatesStep : TC2Graph -> TC2Graph
unifyImmediatesStep graph =
  graph
  |> Dict.foldl
      (\id tc2set graph ->
        let (constraintsToUnify, otherConstraints) =
          Set.toList tc2set |> List.partition tc2IsImmediatelyUnifiable
        in
        case constraintsToUnify of
          tc2A::tc2B::rest ->
            case unifyImmediate tc2A tc2B graph of
              Just (unifiedConstraint, newGraphNodes) ->
                let
                  newTC2Set = (unifiedConstraint::rest) ++ otherConstraints |> Set.fromList
                  newGraph  = Utils.insertAll ((id, newTC2Set) :: newGraphNodes) graph
                in
                newGraph

              Nothing ->
                -- Waiting on TC2App
                graph

          _ ->
            graph
      )
      graph


-- Is this a constraint we can unify pair-wise?
tc2IsImmediatelyUnifiable : TC2 -> Bool
tc2IsImmediatelyUnifiable tc2 =
  case tc2 of
    TC2SameAs _        -> False
    TC2Empty _         -> False
    TC2App _ _ _       -> True
    TC2Unify _ _ _ _ _ -> False
    TC2UnifyOne _ _ _  -> False
    _                  -> True


-- Unifications that will (almost!) always result in one fewer TC2 on this node, at the cost of perhaps extra graph nodes.
-- Returns unified TC2 and any new graph nodes (deferred unification).
-- Assumes not given any: TC2SameAs, TC2Empty, TC2App, TC2Unify, or TC2UnifyOne
unifyImmediate : TC2 -> TC2 -> TC2Graph -> Maybe (TC2, List (TC2Id, Set TC2))
unifyImmediate tc2A tc2B graph =
  let typeMismatch () =
    Just (TC2Empty <| "Types don't match: " ++ toString tc2A ++ " vs. " ++ toString tc2B, [])
  in
  case (tc2A, tc2B) of
    (TC2SameAs _, _)        -> Debug.crash "Shouldn't have TC2SameAs in unifyImmediate"
    (_, TC2SameAs _)        -> Debug.crash "Shouldn't have TC2SameAs in unifyImmediate"
    (TC2Empty _, _)         -> Debug.crash "Shouldn't have TC2Empty in unifyImmediate"
    (_, TC2Empty _)         -> Debug.crash "Shouldn't have TC2Empty in unifyImmediate"
    (TC2Unify _ _ _ _ _, _) -> Debug.crash "Shouldn't have TC2Unify in unifyImmediate"
    (_, TC2Unify _ _ _ _ _) -> Debug.crash "Shouldn't have TC2Unify in unifyImmediate"
    (TC2UnifyOne _ _ _, _)  -> Debug.crash "Shouldn't have TC2UnifyOne in unifyImmediate"
    (_, TC2UnifyOne _ _ _)  -> Debug.crash "Shouldn't have TC2UnifyOne in unifyImmediate"

    (TC2Union tc2AIds, tc2B) ->
      let
        currentId = nextUnusedId graph
        unificationNodes =
          tc2AIds
          |> Utils.mapi0 (\(i, tc2AId)-> (currentId + i, Set.singleton <| TC2UnifyOne tc2AId Nothing tc2B))
        (newIds, _) = List.unzip unificationNodes
      in
      Just <|
        ( TC2Union newIds
        , unificationNodes
        )

    (_, TC2Union _) ->
      unifyImmediate tc2B tc2A graph

    ( TC2App tc2ALeftId tc2ARightId _
    , TC2App tc2BLeftId tc2BRightId _ ) ->
      let
        currentId = nextUnusedId graph
        leftUnificatioNode  = (currentId,     Set.singleton <| TC2Unify tc2ALeftId  tc2BLeftId Nothing Nothing Nothing)
        rightUnificatioNode = (currentId + 1, Set.singleton <| TC2Unify tc2ARightId tc2BRightId Nothing Nothing Nothing)
        ((leftId, _), (rightId, _)) = (leftUnificatioNode, rightUnificatioNode)
      in
      Just <|
        ( TC2App leftId rightId Nothing
        , [leftUnificatioNode, rightUnificatioNode]
        )

    (TC2App tc2ALeftId tc2ARightId _, _) -> Nothing
    (_, TC2App tc2BLeftId tc2BRightId _) -> Nothing

    (TC2Num,    TC2Num)    -> Just (TC2Num,    [])
    (TC2Bool,   TC2Bool)   -> Just (TC2Bool,   [])
    (TC2String, TC2String) -> Just (TC2String, [])
    (TC2Null,   TC2Null)   -> Just (TC2Null,   [])

    -- Explicit to let exhaustiveness checker help us ensure we didn't miss anything.
    (TC2Num,    _)         -> typeMismatch ()
    (TC2Bool,   _)         -> typeMismatch ()
    (TC2String, _)         -> typeMismatch ()
    (TC2Null,   _)         -> typeMismatch ()


    ( TC2Tuple aN tc2AIds maybeTC2ATailId
    , TC2Tuple bN tc2BIds maybeTC2BTailId ) ->
      let
        doUnify currentId tc2AIds maybeTC2ATailId tc2BIds maybeTC2BTailId =
          case ( tc2AIds
               , tc2BIds ) of
            ( tc2AId::aRestHeads
            , tc2BId::bRestHeads ) ->
              let ((headIds, maybeTailId), newNodes) = doUnify (currentId + 1) aRestHeads maybeTC2ATailId bRestHeads maybeTC2BTailId in
              ( (currentId::headIds, maybeTailId)
              , (currentId, Set.singleton <| TC2Unify tc2AId tc2BId Nothing Nothing Nothing)::newNodes
              )

            ( []
            , [] ) ->
              case (maybeTC2ATailId, maybeTC2BTailId) of
                (Nothing, Nothing) -> -- Create-a-tail!
                  ( ([], Just currentId)
                  , [(currentId, Set.empty)]
                  )

                (Just tc2ATailId, Nothing) ->
                  ( ([], Just tc2ATailId)
                  , []
                  )

                (Nothing, Just tc2BTailId) ->
                  ( ([], Just tc2BTailId)
                  , []
                  )

                (Just tc2ATailId, Just tc2BTailId) ->
                  ( ([], Just currentId)
                  , [(currentId, Set.singleton <| TC2Unify tc2ATailId tc2BTailId Nothing Nothing Nothing)]
                  )

            ( []
            , leftoverBIds ) ->
              let
                tailIds = [maybeTC2ATailId, maybeTC2BTailId] |> Utils.filterJusts
                ids     = leftoverBIds ++ tailIds
                rewrittenNodes      = ids |> List.map (\tc2Id -> (tc2Id, Set.insert (TC2SameAs currentId) (getTC2Constraints tc2Id graph)))
                tailNodeConstraints = ids |> List.map TC2SameAs |> Set.fromList
              in
              ( ([], Just currentId)
              , rewrittenNodes ++ [(currentId, tailNodeConstraints)]
              )

            ( leftoverAIds
            , [] ) ->
              let
                tailIds = [maybeTC2ATailId, maybeTC2BTailId] |> Utils.filterJusts
                ids     = leftoverAIds ++ tailIds
                rewrittenNodes      = ids |> List.map (\tc2Id -> (tc2Id, Set.insert (TC2SameAs currentId) (getTC2Constraints tc2Id graph)))
                tailNodeConstraints = ids |> List.map TC2SameAs |> Set.fromList
              in
              ( ([], Just currentId)
              , rewrittenNodes ++ [(currentId, tailNodeConstraints)]
              )


        currentId = nextUnusedId graph

        ((headIds, maybeTailId), newNodes) = doUnify currentId tc2AIds maybeTC2ATailId tc2BIds maybeTC2BTailId
      in
      Just <|
        ( TC2Tuple (max aN bN) headIds maybeTailId
        , newNodes
        )

    ( TC2Tuple  n expHeadIds maybeExpTailId
    , TC2PatTuple patHeadIds maybePatTailId ) ->
      let
        doUnify currentId nLeft expHeadIds maybeExpTailId patHeadIds maybePatTailId =
          case ( expHeadIds
               , patHeadIds ) of
            ( expHeadId::expRestHeads
            , patHeadId::patRestHeads ) ->
              case doUnify (currentId + 1) (nLeft - 1) expRestHeads maybeExpTailId patRestHeads maybePatTailId of
                Just ((headIds, maybeTailId), newNodes) ->
                  Just <|
                    ( (currentId::headIds, maybeTailId)
                    , (currentId, Set.singleton <| TC2Unify expHeadId patHeadId Nothing Nothing Nothing)::newNodes
                    )

                Nothing ->
                  Nothing

            ( []
            , [] ) ->
              case (nLeft > 0, maybeExpTailId, maybePatTailId) of
                (True, _, Nothing) -> -- There are list literals longer than the pat requires.
                  Nothing

                (False, _, Nothing) ->
                  Just <|
                    ( ([], Nothing)
                    , []
                    )

                (_, Nothing, Just patTailId) ->
                  Just <|
                    ( ([], Just patTailId)
                    , []
                    )

                (_, Just expTailId, Just patTailId) ->
                  Just <|
                    ( ([], Just currentId)
                    , [(currentId, Set.singleton <| TC2Unify expTailId patTailId Nothing Nothing Nothing)]
                    )

            ( []
            , patHeadId::patRestHeads ) ->
              case maybeExpTailId of
                Just expTailId ->
                  case doUnify (currentId + 1) (nLeft - 1) [] maybeExpTailId patRestHeads maybePatTailId of
                    Just ((headIds, maybeTailId), newNodes) ->
                      Just <|
                        -- Maybe supposed to make TC2Unify nodes here but I'm not smart.
                        ( (patHeadId::headIds, maybeTailId)
                        , [ (patHeadId, Set.insert (TC2SameAs expTailId) (getTC2Constraints patHeadId graph))
                          , (expTailId, Set.insert (TC2SameAs patHeadId) (getTC2Constraints expTailId graph))
                          ] ++ newNodes
                        )

                    Nothing ->
                      Nothing

                Nothing ->
                  Nothing

            ( expHeadId::expRestHeads
            , [] ) ->
              case maybePatTailId of
                Just patTailId ->
                  case doUnify (currentId + 1) (nLeft - 1) expRestHeads maybeExpTailId [] maybePatTailId of
                    Just ((headIds, maybeTailId), newNodes) ->
                      Just <|
                        -- Maybe supposed to make TC2Unify nodes here but I'm not smart.
                        ( (expHeadId::headIds, maybeTailId)
                        , [ (expHeadId, Set.insert (TC2SameAs patTailId) (getTC2Constraints expHeadId graph))
                          , (patTailId, Set.insert (TC2SameAs expHeadId) (getTC2Constraints patTailId graph))
                          ] ++ newNodes
                        )

                    Nothing ->
                      Nothing

                Nothing ->
                  Nothing


        currentId = nextUnusedId graph
      in
      doUnify currentId n expHeadIds maybeExpTailId patHeadIds maybePatTailId
      |> Maybe.map
          (\((headIds, maybeTailId), newNodes) ->
            ( TC2PatTuple headIds maybeTailId
            , newNodes
            )
          )

    ( TC2PatTuple patHeadIds maybePatTailId
    , TC2Tuple  n expHeadIds maybeExpTailId ) ->
      unifyImmediate tc2B tc2A graph

    ( TC2PatTuple tc2AIds Nothing
    , TC2PatTuple tc2BIds Nothing ) ->
      case Utils.maybeZip tc2AIds tc2BIds of
        Just headsMatched ->
          let
            currentId = nextUnusedId graph
            headUnificationNodes =
              headsMatched
              |> Utils.mapi0 (\(i, (tc2AId, tc2BId)) -> (currentId + i, Set.singleton <| TC2Unify tc2AId tc2BId Nothing Nothing Nothing))
            (headIds, _) = List.unzip headUnificationNodes
          in
          Just <|
            ( TC2PatTuple headIds Nothing
            , headUnificationNodes
            )

        Nothing ->
          Just <|
            ( TC2Empty "Tuples differ in length"
            , []
            )

    ( TC2PatTuple tc2AIds Nothing
    , TC2PatTuple tc2BIds (Just tc2BTailId) ) ->
      case Utils.zipAndLeftovers tc2AIds tc2BIds of
        (_, _, _::_) ->
          Just <|
            ( TC2Empty "Tuple too short to match heads of list"
            , []
            )

        (headsMatched, leftoverAIds, _) ->
          let
            currentId = nextUnusedId graph
            headUnificationNodes =
              headsMatched
              |> Utils.mapi0 (\(i, (tc2AId, tc2BId)) -> (currentId + i, Set.singleton <| TC2Unify tc2AId tc2BId Nothing Nothing Nothing))
            (headIds, _) = List.unzip headUnificationNodes
            newCurrentId = currentId + List.length headUnificationNodes
            moreHeadUnificationNodes =
              leftoverAIds
              |> Utils.mapi0 (\(i, tc2AId)-> (newCurrentId + i, Set.singleton <| TC2Unify tc2AId tc2BTailId Nothing Nothing Nothing))
            (moreHeadIds, _) = List.unzip moreHeadUnificationNodes
          in
          Just <|
            ( TC2PatTuple (headIds ++ moreHeadIds) Nothing
            , headUnificationNodes ++ moreHeadUnificationNodes
            )

    ( TC2PatTuple _ (Just _)
    , TC2PatTuple _ Nothing ) ->
      unifyImmediate tc2B tc2A graph

    ( TC2PatTuple tc2AIds (Just tc2ATailId)
    , TC2PatTuple tc2BIds (Just tc2BTailId) ) ->
      let
        currentId = nextUnusedId graph
        (headsMatched, leftoverAIds, leftoverBIds) = Utils.zipAndLeftovers tc2AIds tc2BIds
        headUnificationNodes =
          headsMatched
          |> Utils.mapi0 (\(i, (tc2AId, tc2BId)) -> (currentId + i, Set.singleton <| TC2Unify tc2AId tc2BId Nothing Nothing Nothing))
        (headIds, _)        = List.unzip headUnificationNodes
        tailId              = currentId + List.length headUnificationNodes
        tailUnificationNode = (tailId, Set.singleton <| TC2Unify tc2ATailId tc2BTailId Nothing Nothing Nothing)
        newCurrentId        = 1 + tailId
        moreHeadUnificationNodes =
          case (leftoverAIds, leftoverBIds) of
            (_, []) -> leftoverAIds |> Utils.mapi0 (\(i, tc2AId)-> (newCurrentId + i, Set.singleton <| TC2Unify tc2AId tc2BTailId Nothing Nothing Nothing))
            ([], _) -> leftoverBIds |> Utils.mapi0 (\(i, tc2BId)-> (newCurrentId + i, Set.singleton <| TC2Unify tc2BId tc2ATailId Nothing Nothing Nothing))
            _       -> Debug.crash "zipAndLeftovers violated its invariant that one leftovers list should be empty!"
        (moreHeadIds, _) = List.unzip moreHeadUnificationNodes
      in
      Just <|
        ( TC2PatTuple (headIds ++ moreHeadIds) (Just tailId)
        , headUnificationNodes ++ moreHeadUnificationNodes ++ [tailUnificationNode]
        )

    (TC2Tuple _ _ _, _)  -> typeMismatch ()
    (TC2PatTuple _ _, _) -> typeMismatch ()

    ( TC2Arrow tc2ALeftId tc2ARightId
    , TC2Arrow tc2BLeftId tc2BRightId ) ->
      let
        currentId = nextUnusedId graph
        leftUnificatioNode  = (currentId,     Set.singleton <| TC2Unify tc2ALeftId  tc2BLeftId Nothing Nothing Nothing)
        rightUnificatioNode = (currentId + 1, Set.singleton <| TC2Unify tc2ARightId tc2BRightId Nothing Nothing Nothing)
        ((leftId, _), (rightId, _)) = (leftUnificatioNode, rightUnificatioNode)
      in
      Just <|
        ( TC2Arrow leftId rightId
        , [leftUnificatioNode, rightUnificatioNode]
        )

    (TC2Arrow _ _, _) -> typeMismatch ()


-- Take only one step at a node at a time.
unifyAcrossNodesStep : TC2Graph -> TC2Graph
unifyAcrossNodesStep graph =
  graph
  |> Dict.foldl
      (\id tc2set graph ->
        let constraintsToUnify =
          Set.toList tc2set |> List.filter tc2IsCrossNodeUnification
        in
        constraintsToUnify
        |> List.foldl
            (\tc2 graph ->
              let
                (newTC2s, graph2) = perhapsUnifyAcrossNodes id tc2 graph
                tc2set            = Utils.justGet_ "SlowTypeInference.unifyAcrossNodesStep" id graph2
                newTC2Set         = tc2set |> Set.remove tc2 |> Utils.insertAllIntoSet newTC2s
                newGraph          = Dict.insert id newTC2Set graph2
              in
              newGraph
            )
            graph
      )
      graph


tc2IsCrossNodeUnification : TC2 -> Bool
tc2IsCrossNodeUnification tc2 =
  case tc2 of
    TC2Unify _ _ _ _ _ -> True
    TC2UnifyOne _ _ _  -> True
    TC2App _ _ _       -> True
    _                  -> False


tc2UnifyNodeCanUnify : TC2 -> Bool
tc2UnifyNodeCanUnify tc2 =
  case tc2 of
    TC2Unify _ _ _ _ _ -> True
    TC2App _ _ _       -> True
    _                  -> tc2IsImmediatelyUnifiable tc2


-- To check if our constraint graph has a cycle.
isPathFromTo : TC2Id -> TC2Id -> TC2Graph -> Bool
isPathFromTo id targetId graph =
  isPathFromTo_ Set.empty [id] targetId graph


-- This function needs to be written tail-recursive otherwise you'll get stack overflows.
isPathFromTo_ : Set TC2Id -> List TC2Id -> TC2Id -> TC2Graph -> Bool
isPathFromTo_ visited toVisit targetId graph =
  case toVisit of
    []            -> False
    id::remaining ->
      if Set.member id visited then
        isPathFromTo_ visited remaining targetId graph
      else
        let
          equivIdSet         = equivalentIds id graph
          constraints        = constraintsOnSubgraph id graph
          constraintChildIds = constraints |> List.concatMap tc2ChildIds
        in
        if Set.member targetId equivIdSet then
          True
        else
          isPathFromTo_ (Set.union equivIdSet visited) (constraintChildIds ++ remaining) targetId graph


-- Gather all constraints on the graph reachable from id.
constraintsOnSubgraph : TC2Id -> TC2Graph -> List TC2
constraintsOnSubgraph id graph =
  constraintsOnSubgraph_ Set.empty [id] graph


constraintsOnSubgraph_ : Set TC2Id -> List TC2Id -> TC2Graph -> List TC2
constraintsOnSubgraph_ visited toVisit graph =
  case toVisit of
    []            -> []
    id::remaining ->
      if Set.member id visited then
        constraintsOnSubgraph_ visited remaining graph
      else
        case Dict.get id graph of
          Just tc2set ->
            let
              newVisited     = Set.insert id visited
              tc2list        = Set.toList tc2set
              newToVisit     = (tc2list |> List.filterMap tc2ToMaybeSameAsId) ++ remaining
              newConstraints = List.filter (not << tc2IsASameAs) tc2list
            in
            newConstraints ++ constraintsOnSubgraph_ newVisited newToVisit graph

          Nothing ->
            constraintsOnSubgraph_ (Set.insert id visited) remaining graph


-- type DownstreamConstraint
--   = Primitive TC2
--   | Cached (Maybe TC2)


-- Returns TC2s to replace this TC2 on the node, plus a possibly modified graph.
perhapsUnifyAcrossNodes : TC2Id -> TC2 -> TC2Graph -> (List TC2, TC2Graph)
perhapsUnifyAcrossNodes thisId tc2 graph =
  let noChange = ([tc2], graph) in
  let perhapsPullOutCachedConstraint tc2 =
    case tc2 of
      TC2Unify _ _ _ _ mc -> mc |> Maybe.andThen perhapsPullOutCachedConstraint
      TC2App _ _ mc       -> mc |> Maybe.andThen perhapsPullOutCachedConstraint
      _                   -> Just tc2
  in
  case tc2 of
    TC2Unify aId bId aLastUsedConstraint bLastUsedConstraint cached ->
      let aConstraints = constraintsOnSubgraph aId graph in
      let bConstraints = constraintsOnSubgraph bId graph in
      let allConstraints = aConstraints ++ bConstraints in
      (\result ->
        if result == noChange then
          if isPathFromTo aId thisId graph && not (isPathFromTo bId thisId graph) then
            -- We're stuck, or going to be. Speculatively try to use the other side as the result.
            case List.map perhapsPullOutCachedConstraint bConstraints of
              [Just bConstraint] ->
                if bLastUsedConstraint == Just bConstraint then
                  noChange
                else
                  ( [TC2Unify aId bId aLastUsedConstraint (Just bConstraint) (Just bConstraint)]
                  , graph
                  )
              _ ->
                noChange

          else if isPathFromTo bId thisId graph && not (isPathFromTo aId thisId graph) then
            -- We're stuck, or going to be. Speculatively try to use the other side as the result.
            case List.map perhapsPullOutCachedConstraint aConstraints of
              [Just aConstraint] ->
                if aLastUsedConstraint == Just aConstraint then
                  noChange
                else
                  ( [TC2Unify aId bId (Just aConstraint) bLastUsedConstraint (Just aConstraint)]
                  , graph
                  )
              _ ->
                noChange
          else
            noChange
        else
          result
      ) <|
      if List.any tc2IsEmpty allConstraints then
        -- If empty, simply halt computation.
        noChange
      else if not <| List.all tc2UnifyNodeCanUnify allConstraints then
        -- Wait for downstream computation.
        noChange
      else
        case ( List.map perhapsPullOutCachedConstraint aConstraints
             , List.map perhapsPullOutCachedConstraint bConstraints
             ) of

          ([], []) ->
            -- Any added connections need to be bidirectional.
            ( [TC2SameAs aId, TC2SameAs bId]
            , graph |> addTC2ToGraph aId (TC2SameAs thisId) |> addTC2ToGraph bId (TC2SameAs thisId)
            )

          -- Could probably find maximal superset (subtype) and insert that into other side instead.
          ([(Just aConstraint) as justAConstraint], []) ->
            let
              rightSubgraphCanonicalId = canonicalId bId graph
              justRightSubgraphSameAs  = Just (TC2SameAs rightSubgraphCanonicalId)
            in
            if aLastUsedConstraint == justAConstraint && bLastUsedConstraint == justRightSubgraphSameAs then
              noChange
            else
              ( [TC2Unify aId bId justAConstraint justRightSubgraphSameAs (justAConstraint)]
              , graph |> addTC2ToGraph rightSubgraphCanonicalId aConstraint
              )

          ([], [(Just bConstraint) as justBConstraint]) ->
            let
              leftSubgraphCanonicalId = canonicalId aId graph
              justLeftSubgraphSameAs  = Just (TC2SameAs leftSubgraphCanonicalId)
            in
            if aLastUsedConstraint == justLeftSubgraphSameAs && bLastUsedConstraint == justBConstraint then
              noChange
            else
              ( [TC2Unify aId bId justLeftSubgraphSameAs justBConstraint (justBConstraint)]
              , graph |> addTC2ToGraph leftSubgraphCanonicalId bConstraint
              )

          ([Nothing], []) -> noChange
          ([], [Nothing]) -> noChange

          ( [(Just aConstraint) as justAConstraint]
          , [(Just bConstraint) as justBConstraint]
          ) ->
            if aLastUsedConstraint == justAConstraint && bLastUsedConstraint == justBConstraint then
              noChange
            else
              case unifyImmediate aConstraint bConstraint graph of
                Just (unifiedConstraint, newGraphNodes) ->
                  ( [TC2Unify aId bId justAConstraint justBConstraint (Just unifiedConstraint)]
                  , Utils.insertAll newGraphNodes graph
                  )
                Nothing ->
                  -- Wait for downstream EApp computation.
                  noChange

          _ ->
            -- Wait for downstream computation.
            noChange

    TC2App fId argId cached ->
      let fConstraints = constraintsOnSubgraph fId graph in
      let argConstraints = constraintsOnSubgraph argId graph in
      let allConstraints = fConstraints ++ argConstraints in
      if List.any tc2IsEmpty allConstraints then
        -- If empty, simply halt computation.
        noChange
      else if not <| List.all tc2UnifyNodeCanUnify allConstraints then
        -- Wait for downstream computation.
        noChange
      else
        case ( List.map perhapsPullOutCachedConstraint fConstraints
             , List.map perhapsPullOutCachedConstraint argConstraints
             ) of

          ([], _) ->
            let
              newId          = nextUnusedId graph
              newFConstraint = TC2Arrow argId newId
            in
            ( [TC2App fId argId Nothing]
            , graph |> addTC2ToGraph fId (TC2Arrow argId newId)
            )

          ([Just (TC2Arrow fromId toId)], []) ->
            let
              fromConstraints = constraintsOnSubgraph fromId graph
              toConstraints   = constraintsOnSubgraph toId graph
              -- fromIsTo        = canonicalId fromId graph == canonicalId toId graph
            in
            ( [TC2App fId argId Nothing] -- (if fromIsTo then Just (TC2SameAs argId) else Nothing)] Can't handle polymorphism yet
            , fromConstraints |> Utils.foldl graph (\fromTC2 graph -> addTC2ToGraph argId fromTC2 graph)
            )

          ([Nothing], []) -> noChange

          ( [Just (TC2Arrow fromId toId)]
          , [Just argConstraint]
          ) ->
            let
              fromConstraints         = constraintsOnSubgraph fromId graph
              toConstraints           = constraintsOnSubgraph toId graph
              fromConstraintsFollowed = fromConstraints |> List.map perhapsPullOutCachedConstraint
              toConstraintsFollowed   = toConstraints   |> List.map perhapsPullOutCachedConstraint
            in
            case (fromConstraintsFollowed, toConstraintsFollowed) of
              ([Just fromConstraint], [Just toConstraint]) ->
                let
                  maybeFromType = tc2ToType fromConstraint graph
                  maybeArgType  = tc2ToType argConstraint graph
                  -- _ = Debug.log "TC2App" (maybeFromType |> Maybe.map (Syntax.typeUnparser Syntax.Elm), maybeArgType |> Maybe.map (Syntax.typeUnparser Syntax.Elm))
                in
                if maybeFromType /= Nothing && maybeFromType == maybeArgType then -- Super conservative application.
                  ( [TC2App fId argId (Just toConstraint)]
                  , graph
                  )
                else
                  ( [TC2App fId argId Nothing]
                  , graph
                  )

              _ ->
                ( [TC2App fId argId Nothing]
                , graph
                )

          _ ->
            -- Wait for downstream computation.
            noChange

    TC2UnifyOne otherId lastUsedConstraint constraint ->
      -- UnifyOne are produced by unions.
      -- B/c unions represent alternative worlds, can't propagate constraints to existing graph nodes.
      -- Would need self-contained worlds, here. However, instead we'll just try to narrow the given
      -- constraint to a fixed depth and, if that fails, so be it.
      let otherConstraints = constraintsOnSubgraph otherId graph in
      if tc2IsEmpty constraint || List.any tc2IsEmpty otherConstraints then
        -- Signal failed union path
        ( [Utils.findFirst tc2IsEmpty (constraint::otherConstraints) |> Maybe.withDefault (TC2Empty "Dead union path")]
        , graph
        )
      else if not <| List.all tc2UnifyNodeCanUnify otherConstraints then
        -- Wait for downstream computation.
        noChange
      else
        case (otherConstraints, constraint) of
          ([], _) ->
            -- Union shouldn't constrain a type var.
            -- Should probably wait for graph to settle before resolving unions like this, however.
            ( [TC2Empty "Union shouldn't constrain a type variable"]
            , graph
            )

          (_, TC2Unify _ _ _ _ Nothing) -> -- Can this even happen??
            -- Wait for downstream computation
            noChange

          ([otherConstraint], TC2Unify _ _ _ _ (Just constraint)) -> -- Can this even happen??
            if Just otherConstraint == lastUsedConstraint then
              noChange
            else
              case unifyImmediate otherConstraint constraint graph of
                Just (unifiedConstraint, newGraphNodes) ->
                  let
                    newGraphNodesSimplified =
                      newGraphNodes
                      |> List.map
                          (\(id, tc2set) ->
                            case tc2set |> Set.toList of
                              [TC2Unify aId bId _ _ _] ->
                                if equivalentIds aId graph == equivalentIds bId graph
                                then Just (id, aId)
                                else Nothing

                              _ ->
                                Nothing
                          )
                      |> Utils.projJusts
                  in
                  case newGraphNodesSimplified of
                    Just tc2Subst ->
                      ( [TC2UnifyOne otherId (Just otherConstraint) (applyTC2IdSubst (Dict.fromList tc2Subst) unifiedConstraint)]
                      , graph
                      )

                    Nothing ->
                      ( [TC2Empty "Can't unify for union"]
                      , graph
                      )

                Nothing ->
                  -- Wait for downstream TC2App computation
                  noChange

          ([otherConstraint], _) ->
            if Just otherConstraint == lastUsedConstraint then
              noChange
            else
              case unifyImmediate otherConstraint constraint graph of
                Just (unifiedConstraint, newGraphNodes) ->
                  let
                    newGraphNodesSimplified =
                      newGraphNodes
                      |> List.map
                          (\(id, tc2set) ->
                            case tc2set |> Set.toList of
                              [TC2Unify aId bId _ _ _] ->
                                if equivalentIds aId graph == equivalentIds bId graph
                                then Just (id, aId)
                                else Nothing

                              _ ->
                                Nothing
                          )
                      |> Utils.projJusts
                  in
                  case newGraphNodesSimplified of
                    Just tc2Subst ->
                      ( [TC2UnifyOne otherId (Just otherConstraint) (applyTC2IdSubst (Dict.fromList tc2Subst) unifiedConstraint)]
                      , graph
                      )

                    Nothing ->
                      ( [TC2Empty "Can't unify for union"]
                      , graph
                      )

                Nothing ->
                  -- Wait for downstream TC2App computation
                  noChange


          (_::_::_, _) ->
            -- Wait for downstream computation
            noChange

    _ ->
      noChange


buildConnectedComponents : TC2Graph -> TC2Graph
buildConnectedComponents graph =
  let newGraph = propagateGraphConstraints graph in
  if graph == newGraph
  then graph
  else buildConnectedComponents newGraph


unifyConstraintsUntilFixpoint : Exp -> Int -> TC2Graph -> TC2Graph
unifyConstraintsUntilFixpoint program maxIterations graph =
  unifyConstraintsUntilFixpoint_ program maxIterations graph
  -- let buildConnectedComponents graph =
  --   let newGraph = propagateGraphConstraints graph in
  --   if graph == newGraph
  --   then graph
  --   else buildConnectedComponents newGraph
  -- in
  -- -- After this point, if need to add a SameAs node be sure to re-run buildConnectedComponents UNLESS
  -- -- (a) You are sure there are no constraints on at least one of the components you are connecting AND
  -- -- (b) You make sure the connecting edge is bidirectional
  -- unifyConstraintsUntilFixpoint_ maxIterations (buildConnectedComponents graph)


unifyConstraintsUntilFixpoint_ : Exp -> Int -> TC2Graph -> TC2Graph
unifyConstraintsUntilFixpoint_ program maxIterations graph =
  if maxIterations <= 0 then
    graph
  else
    -- let _ = Debug.log ("Iterations remaining " ++ toString maxIterations) graph in
    -- let _ = Debug.log "unifyConstraintsUntilFixpoint_: Iterations remaining" maxIterations in
    -- let _ = ImpureGoodies.logRaw (graphVizString program graph) in
    let newGraph =
      graph
      |> buildConnectedComponents
      |> unifyImmediatesStep
      |> unifyAcrossNodesStep
    in
    if graph == newGraph then
      graph
    else
      unifyConstraintsUntilFixpoint_ program (maxIterations - 1) newGraph


tc2ToType : TC2 -> TC2Graph -> Maybe Type
tc2ToType tc2 graph =
  let recurse id = tc2IdToType id graph in
  case tc2 of
    TC2SameAs _                          -> Nothing
    TC2Empty message                     -> Nothing
    TC2Unify idl idr ml mr (Just cached) -> tc2ToType cached graph
    TC2Unify idl idr ml mr Nothing       -> Nothing
    TC2App idl idr (Just cached)         -> tc2ToType cached graph
    TC2App idl idr Nothing               -> Nothing
    TC2UnifyOne id ml cached             -> tc2ToType cached graph
    TC2Num                               -> Just <| Types.tNum
    TC2Bool                              -> Just <| Types.tBool
    TC2String                            -> Just <| Types.tString
    TC2Null                              -> Just <| Types.tNull
    TC2Tuple n headIds mTailId           ->
      List.map recurse headIds
      |> Utils.projJusts
      |> Maybe.andThen
          (\heads ->
            case Maybe.map recurse mTailId of
              (Just Nothing) -> Nothing
              mmTailType     ->
                let maybeTail    = mmTailType |> Maybe.withDefault Nothing in
                let nonTailHeads = heads |> List.map Just |> List.filter ((/=) maybeTail) in
                case (nonTailHeads, Utils.dedup heads, maybeTail) of
                  ([], _, Just tail)   -> Just <| withDummyRange <| TList space1 tail space0
                  (_, [head], Nothing) ->
                    if List.length heads == 2 && head == Types.tNum
                    then Just <| withDummyRange <| TTuple space1 heads space1 Nothing space0 -- Exception for points
                    else Just <| withDummyRange <| TList space1 head space0
                  (_, _, maybeTail)    -> Just <| withDummyRange <| TTuple space1 heads space1 maybeTail space0
          )
    TC2PatTuple headIds mTailId          ->
      List.map recurse headIds
      |> Utils.projJusts
      |> Maybe.andThen
          (\heads ->
            case Maybe.map recurse mTailId of
              (Just Nothing) -> Nothing
              mmTailType     ->
                let maybeTail    = mmTailType |> Maybe.withDefault Nothing in
                let nonTailHeads = heads |> List.map Just |> List.filter ((/=) maybeTail) in
                case (nonTailHeads, maybeTail) of
                  ([], Just tail) -> Just <| withDummyRange <| TList space1 tail space0
                  (_,  maybeTail) -> Just <| withDummyRange <| TTuple space1 heads space1 maybeTail space0
          )
    TC2Arrow idl idr                     ->
      [recurse idl, recurse idr]
      |> Utils.projJusts
      |> Maybe.map (\types -> Types.inlineArrow <| withDummyRange <| TArrow space1 types space0)
    TC2Union ids                         ->
      List.map recurse ids
      |> Utils.projJusts
      |> Maybe.map (\types -> withDummyRange <| TUnion space1 types space0)


tc2IdToType : TC2Id -> TC2Graph -> Maybe Type
tc2IdToType id graph =
  case constraintsOnSubgraph id graph of
    [] -> Just <| withDummyRange <| TVar space1 ("a" ++ toString (canonicalId id graph))
    constraints  ->
      case constraints |> List.map (\constraint -> tc2ToType constraint graph) |> Utils.dedup of
        [maybeType] -> maybeType
        _           -> Nothing


maybeTypes : TC2Id -> TC2Graph -> List Type
maybeTypes id graph =
  case constraintsOnSubgraph id graph of
    []          -> [withDummyRange <| TVar space1 ("a" ++ toString (canonicalId id graph))]
    constraints ->
      -- let _ = Debug.log "constraints" constraints in
      constraints |> List.filterMap (\tc2 -> tc2ToType tc2 graph)


maybeType : TC2Id -> TC2Graph -> Maybe Type
maybeType id graph = tc2IdToType id graph


-- Optimistic even if typechecking didn't complete (e.g. not all type applications could be resolved).
typeIsOkaySoFar : TC2Id -> TC2Graph -> Bool
typeIsOkaySoFar id graph =
  case constraintsOnSubgraph id graph of
    []          -> True
    constraints ->
      not (List.any tc2IsEmpty constraints) &&
      1 == List.length (List.filterMap (\tc2 -> tc2ToType tc2 graph) constraints)


---------------------------------------------------------------------------


-- Send program in just because it's the easiest way to find the max id.
constraintsToTypeConstraints2 : Exp -> List Constraint -> TC2Graph
constraintsToTypeConstraints2 program constraints =
  let
    currentId : TC2Id
    currentId = 1 + FastParser.maxId program

    -- Returns (newCurrentId, tc2Ids of added nodes, newGraph)
    addTCSToGraph : List (Ident, TC2Id) -> TC2Id -> List TypeConstraint -> TC2Graph -> (TC2Id, List TC2Id, TC2Graph)
    addTCSToGraph typeVarToTC2Id currentId tcs graph =
      tcs
      |> List.foldl
          (\tc (currentId, tc2Ids, graph) ->
            let (newCurrentId, tc2Id, newGraph) = addTCToGraph typeVarToTC2Id currentId tc graph in
            (newCurrentId, tc2Ids ++ [tc2Id], newGraph)
          )
          (currentId, [], graph)

    -- Returns (newCurrentId, tc2Id of added node, newGraph)
    addTCToGraph : List (Ident, TC2Id) -> TC2Id -> TypeConstraint -> TC2Graph -> (TC2Id, TC2Id, TC2Graph)
    addTCToGraph typeVarToTC2Id currentId tc graph =
      case tc of
        TCEId eid            -> (currentId, eid, graph)
        TCPId pid            -> (currentId, pid, graph)
        TCApp tc1 []         -> addTCToGraph typeVarToTC2Id currentId tc1 graph -- Shouldn't happen, but this is correct if it does.
        TCApp tc1 [tc2]      ->
          let
            (currentId2, tc1_tc2Id, graph2) = addTCToGraph typeVarToTC2Id currentId tc1 graph
            (currentId3, tc2_tc2Id, graph3) = addTCToGraph typeVarToTC2Id currentId2 tc2 graph2
            finalGraph = addTC2ToGraph currentId3 (TC2App tc1_tc2Id tc2_tc2Id Nothing) graph3
          in
          (currentId3 + 1, currentId3, finalGraph)
        TCApp tc1 tcs        ->
          let desugarTCApp tc1 tcs =
            case tcs of
              []       -> tc1
              tc2::tcs -> desugarTCApp (TCApp tc1 [tc2]) tcs
          in
          addTCToGraph typeVarToTC2Id currentId (desugarTCApp tc1 tcs) graph

        -- TCApp tc1 tcs       ->
        --   let
        --     (currentId2, tc1_tc2Id,  graph2) = addTCToGraph typeVarToTC2Id currentId tc1 graph
        --     (currentId3, tcs_tc2Ids, graph3) = addTCSToGraph typeVarToTC2Id currentId2 tcs graph2
        --     finalGraph = addTC2ToGraph currentId3 (TC2App tc1_tc2Id tcs_tc2Ids) graph3
        --   in
        --   (currentId3 + 1, currentId3, finalGraph)
        TCNum                -> (currentId + 1, currentId, addTC2ToGraph currentId TC2Num    graph)
        TCBool               -> (currentId + 1, currentId, addTC2ToGraph currentId TC2Bool   graph)
        TCString             -> (currentId + 1, currentId, addTC2ToGraph currentId TC2String graph)
        TCNull               -> (currentId + 1, currentId, addTC2ToGraph currentId TC2Null   graph)
        TCList tc1           ->
          let
            (currentId2, tc1_tc2Id, graph2) = addTCToGraph typeVarToTC2Id currentId tc1 graph
            finalGraph = addTC2ToGraph currentId2 (TC2Tuple maxSafeInt [] (Just tc1_tc2Id)) graph2
          in
          (currentId2 + 1,  currentId2, finalGraph)
        TCTuple tcs mtc     ->
          let
            (currentId2, tcs_tc2Ids, graph2) = addTCSToGraph typeVarToTC2Id currentId tcs graph
            (currentId3, maybe_tc2Id, graph3) =
              case mtc of
                Nothing     -> (currentId2,     Nothing,         graph2)
                Just tailTC -> addTCToGraph typeVarToTC2Id currentId2 tailTC graph2 |> Utils.mapSnd3 Just
            finalGraph = addTC2ToGraph currentId3 (TC2Tuple (List.length tcs) tcs_tc2Ids maybe_tc2Id) graph3
          in
          (currentId3 + 1, currentId3, finalGraph)
        TCPatTuple tcs mtc     ->
          let
            (currentId2, tcs_tc2Ids, graph2) = addTCSToGraph typeVarToTC2Id currentId tcs graph
            (currentId3, maybe_tc2Id, graph3) =
              case mtc of
                Nothing     -> (currentId2,     Nothing,         graph2)
                Just tailTC -> addTCToGraph typeVarToTC2Id currentId2 tailTC graph2 |> Utils.mapSnd3 Just
            finalGraph = addTC2ToGraph currentId3 (TC2PatTuple tcs_tc2Ids maybe_tc2Id) graph3
          in
          (currentId3 + 1, currentId3, finalGraph)
        TCArrow []           -> let _ = Utils.log <| "WAT: Why is there an empty TCArrow in addTCToGraph?" in (currentId + 1, currentId, addTC2ToGraph currentId (TC2Empty "Empty arrow") graph)
        TCArrow [tc1]        -> addTCToGraph typeVarToTC2Id currentId tc1 graph
        TCArrow (tc1::tcs)   ->
          let
            (currentId2, tc1_tc2Id, graph2) = addTCToGraph typeVarToTC2Id currentId tc1 graph
            (currentId3, tcs_tc2Id, graph3) = addTCToGraph typeVarToTC2Id currentId2 (TCArrow tcs) graph2
            finalGraph = addTC2ToGraph currentId3 (TC2Arrow tc1_tc2Id tcs_tc2Id) graph3
          in
          (currentId3 + 1, currentId3, finalGraph)
        TCUnion tcs          ->
          let
            (currentId2, tcs_tc2Ids, graph2) = addTCSToGraph typeVarToTC2Id currentId tcs graph
            finalGraph = addTC2ToGraph currentId2 (TC2Union tcs_tc2Ids) graph2
          in
          (currentId2 + 1, currentId2, finalGraph)
        TCNamed _            -> let _ = Utils.log <| "BUG: All type aliases should be resolved by constraintsToTypeConstraints2 but encountered " ++ toString tc ++ "!" in (currentId + 1, currentId, graph)
        TCVar ident          ->
          case Utils.maybeFind ident typeVarToTC2Id of
            Just tc2Id -> (currentId, tc2Id, graph)
            Nothing    -> let _ = Utils.log <| "MALFORMED TYPE: type var " ++ ident ++ " not found in type env " ++ toString typeVarToTC2Id ++ ". All types with vars should be wrapped in forall!!!" in (currentId + 1, currentId, graph)
        TCForall idents tc1  ->
          let newTypeVarToTC2Id =
            idents
            |> Utils.zipi_ currentId
            |> List.map Utils.flip
          in
          addTCToGraph (newTypeVarToTC2Id ++ typeVarToTC2Id) (currentId + List.length newTypeVarToTC2Id) tc1 graph
        TCWildcard           -> (currentId + 1, currentId, graph)
  in
  let (_, _, finalGraph) =
    constraints
    |> List.foldl
        (\constraint (currentId, uniqueNameToTC2Id, graph) ->
          case constraint of
            EIdIsType eid tc ->
              let (newCurrentId, tc2Id, graphWithTC2) = addTCToGraph [] currentId tc graph in
              ( newCurrentId
              , uniqueNameToTC2Id
              , graphWithTC2 |> addIdsEdgeToGraph eid tc2Id
              )

            PIdIsType pid tc ->
              let (newCurrentId, tc2Id, graphWithTC2) = addTCToGraph [] currentId tc graph in
              ( newCurrentId
              , uniqueNameToTC2Id
              , graphWithTC2 |> addIdsEdgeToGraph pid tc2Id
              )

            PIdIsEId pid eid ->
              ( currentId
              , uniqueNameToTC2Id
              , graph |> addIdsEdgeToGraph pid eid
              )

            EIdVar eid ident ->
              case Dict.get ident uniqueNameToTC2Id of
                Just tc2Id ->
                  ( currentId
                  , uniqueNameToTC2Id
                  , graph |> addIdsEdgeToGraph eid tc2Id
                  )

                Nothing ->
                  ( currentId + 1
                  , Dict.insert ident currentId uniqueNameToTC2Id
                  , graph |> addIdsEdgeToGraph eid currentId
                  )

            PIdVar pid ident ->
              case Dict.get ident uniqueNameToTC2Id of
                Just tc2Id ->
                  ( currentId
                  , uniqueNameToTC2Id
                  , graph |> addIdsEdgeToGraph pid tc2Id
                  )

                Nothing ->
                  ( currentId + 1
                  , Dict.insert ident currentId uniqueNameToTC2Id
                  , graph |> addIdsEdgeToGraph pid currentId
                  )

            EIdIsEmpty eid str ->
              ( currentId
              , uniqueNameToTC2Id
              , graph |> addTC2ToGraph eid (TC2Empty str)
              )

            PIdIsEmpty pid str ->
              ( currentId
              , uniqueNameToTC2Id
              , graph |> addTC2ToGraph pid (TC2Empty str)
              )

            TypeAlias ident tc ->
              let _ = Utils.log <| "BUG: Type aliases should be gone by constraintsToTypeConstraints2 but encountered constraint " ++ toString constraint in
              ( currentId
              , uniqueNameToTC2Id
              , graph
              )
        )
        (currentId, Dict.empty, Dict.empty)
  in
  finalGraph


maxIterations : Int
maxIterations = 100


typecheck : Exp -> TC2Graph
typecheck program =
  let (programUniqueNames, _) = LangTools.assignUniqueNames program in
  -- let _ = Utils.log <| Syntax.unparser Syntax.Elm programUniqueNames in
  programUniqueNames
  |> gatherConstraints
  -- Can't typecheck prelude, but we at least want the type for concat.
  -- Actually, the type inference is still too primitive to type the recursive kochCurve, but
  -- having this eliminates one failure point if we ever tackle that.
  |> (++) [EIdVar 1 "concat", EIdIsType 1 (TCForall ["a"] <| TCArrow [TCList (TCList (TCVar "a")), TCList (TCVar "a")])]
  |> expandTypeAliases
  |> constraintsToTypeConstraints2 program
  |> unifyConstraintsUntilFixpoint program maxIterations


-- $ pbpaste | dot -Tpdf > type_graph.pdf && open type_graph.pdf
graphVizString : Exp -> TC2Graph -> String
graphVizString program graph =
  let
    tc2ToVariantStr tc2 =
      case tc2 of
        TC2SameAs id                -> "Same as " ++ toString id
        TC2Empty errMsg             -> "Error: " ++ errMsg
        TC2Unify _ _ _ _ cached     -> "Unify, cached: "    ++ Maybe.withDefault "" (Maybe.map tc2ToVariantStr cached)
        TC2UnifyOne _ _ cached      -> "UnifyOne, cached: " ++ tc2ToVariantStr cached
        TC2App _ _ cached           -> "App, cached: "      ++ Maybe.withDefault "" (Maybe.map tc2ToVariantStr cached)
        TC2Num                      -> "Num"
        TC2Bool                     -> "Bool"
        TC2String                   -> "String"
        TC2Null                     -> "Null"
        TC2Tuple n heads maybeTail  -> "(\\largest seen: size " ++ toString n ++ ")[" ++ String.join "," (List.map (always "_") heads) ++ Maybe.withDefault "" (Maybe.map (always "\\|_") maybeTail) ++ "]"
        TC2PatTuple heads maybeTail -> "Pat[" ++ String.join "," (List.map (always "_") heads) ++ Maybe.withDefault "" (Maybe.map (always "\\|_") maybeTail) ++ "]"
        TC2Arrow _ _                -> "Arrow"
        TC2Union _                  -> "Union"

    tc2ToArgIds tc2 =
      case tc2 of
        TC2SameAs id                -> [id]
        TC2Empty errMsg             -> []
        TC2Unify l r _ _ _          -> [l,r]
        TC2UnifyOne id _ _          -> [id]
        TC2App l r _                -> [l,r]
        TC2Num                      -> []
        TC2Bool                     -> []
        TC2String                   -> []
        TC2Null                     -> []
        TC2Tuple n heads maybeTail  -> heads ++ Utils.maybeToList maybeTail
        TC2PatTuple heads maybeTail -> heads ++ Utils.maybeToList maybeTail
        TC2Arrow l r                -> [l, r]
        TC2Union ids                -> ids

    idToCode =
      (flattenExpTree program    |> List.map (\exp -> (exp.val.eid, exp |> Syntax.unparser Syntax.Elm        |> Utils.stringReplace "->" "\\-\\>" |> Utils.squish))) ++
      (LangTools.allPats program |> List.map (\pat -> (pat.val.pid, pat |> Syntax.patternUnparser Syntax.Elm |> Utils.stringReplace "->" "\\-\\>" |> Utils.squish)))
      |> Dict.fromList

    nodesAndEdges =
      graph
      |> Dict.toList
      |> List.concatMap
          (\(id, tc2set) ->
            if id == canonicalId id graph then
              let
                constraints = constraintsOnSubgraph id graph
                -- sameAsIds   = equivalentIds id graph

                -- node12345 [label = "{12345 unparsed}|{TC2Arrow|<c1a1> |<c1a2>}"];

                nodeName = "node" ++ toString id

                nodeBasicLabel = "{" ++ toString id ++ " " ++ Utils.getWithDefault id "" idToCode ++ "}"
                (constraintLabels, constraintEdgeLists) =
                  constraints
                  |> Utils.mapi1
                      (\(constraintI, constraint) ->
                        let (argLabels, argEdges) =
                          tc2ToArgIds constraint
                          |> List.map (\argId -> canonicalId argId graph)
                          |> Utils.mapi1
                              (\(argI, argId) ->
                                let argLabel = "c" ++ toString constraintI ++ "a" ++ toString argI in -- "c1a1"
                                ( "<" ++ argLabel ++ ">"                                              -- "<c1a1>"
                                , nodeName ++ ":" ++ argLabel ++ " -> node" ++ toString argId ++ ";"  -- "node12345:c1a1 -> node8754;"
                                )
                              )
                          |> List.unzip
                        in
                        ( "{" ++ String.join "|" (tc2ToVariantStr constraint :: argLabels) ++ "}"
                        , argEdges
                        )
                      )
                  |> List.unzip

                constraintEdges = List.concat constraintEdgeLists
              in
              [ nodeName ++ " [label = \"" ++ String.join "|" (nodeBasicLabel::constraintLabels) ++ "\"];"
              ] ++ constraintEdges
            else
              case Dict.get id idToCode of
                Just codeStr ->
                  let
                    nodeName = "node" ++ toString id
                    nodeBasicLabel = "{" ++ codeStr ++ "}"
                  in
                  [ nodeName ++ " [label = \"" ++ nodeBasicLabel ++ "\"];"
                  , nodeName ++ " -> node" ++ toString (canonicalId id graph) ++ ";"
                  ]
                Nothing -> []
          )
  in
  "digraph types {\n" ++
  "rankdir=LR;\n" ++
  "node [shape = record];\n" ++
  String.join "\n" nodesAndEdges ++ "\n" ++
  "}"


-- Assumes type aliases are uniquely named.
expandTypeAliases : List Constraint -> List Constraint
expandTypeAliases constraints =
  let
    constraintToMaybeAlias tc =
      case tc of
        TypeAlias ident tc -> Just (ident, tc)
        _                  -> Nothing

    expandAliasInTC aliasName aliasTC tc =
      tc
      |> mapTC
          (\tc ->
            case tc of
              TCNamed ident -> if ident == aliasName then aliasTC else tc
              _             -> tc
          )

    expandAliasInConstraint aliasName aliasTC constraint =
      case constraint of
        EIdIsType eid tc       -> EIdIsType eid (expandAliasInTC aliasName aliasTC tc)
        PIdIsType pid tc       -> PIdIsType pid (expandAliasInTC aliasName aliasTC tc)
        PIdIsEId pid eid       -> constraint
        EIdVar eid ident       -> constraint
        PIdVar pid ident       -> constraint
        EIdIsEmpty eid message -> constraint
        PIdIsEmpty pid message -> constraint
        TypeAlias ident tc     -> TypeAlias ident (expandAliasInTC aliasName aliasTC tc)

  in
  case constraints |> Utils.maybeFindAndRemoveFirst (constraintToMaybeAlias >> Utils.maybeToBool) |> Maybe.map (Tuple.mapFirst constraintToMaybeAlias) of
    Just (Just (aliasName, aliasTC), remainingConstraints) ->
      remainingConstraints
      |> List.map (expandAliasInConstraint aliasName aliasTC)
      |> expandTypeAliases

    _ ->
      constraints


gatherConstraints : Exp -> List Constraint
gatherConstraints exp =
  let eidIs typeConstraint = [EIdIsType exp.val.eid typeConstraint] in
  let expToTC = .val >> .eid >> TCEId in
  let expsToTCs = List.map expToTC in
  let childConstraints = childExps exp |> List.concatMap gatherConstraints in
  childConstraints ++
  case exp.val.e__ of
    EBase _ (EBool _)      -> eidIs TCBool
    EBase _ (EString _ _)  -> eidIs TCString
    EBase _ ENull          -> eidIs TCNull
    EConst _ _ _ _         -> eidIs TCNum
    EVar _ ident           -> [EIdVar exp.val.eid ident]
    EFun _ argPats fBody _ ->
      gatherPatsConstraints False argPats ++
      eidIs (TCArrow <| (argPats |> List.map (.val >> .pid >> TCPId)) ++ [TCEId fBody.val.eid])
    EApp _ fExp argExps _ _     -> eidIs <| TCApp (expToTC fExp) (expsToTCs argExps)
    EList _ heads _ maybeTail _ -> eidIs <| TCTuple (expsToTCs (headExps heads)) (Maybe.map expToTC maybeTail)
    EOp _ op operands _         ->
      case (op.val, operands |> List.map (.val >> .eid)) of
        (Pi,         [])           -> eidIs TCNum
        (ToStr,      [_])          -> eidIs TCString
        (DebugLog,   [eid])        -> eidIs (TCEId eid)
        (Eq,         [eid1, eid2]) -> eidIs TCBool -- (a -> b -> Bool), see Eval.eval
        (Cos,        [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (Sin,        [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (ArcCos,     [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (ArcSin,     [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (ArcTan2,    [eid1, eid2]) -> eidIs TCNum  ++ [EIdIsType eid1 TCNum, EIdIsType eid2 TCNum]
        (Abs,        [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (Floor,      [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (Ceil,       [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (Round,      [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (Sqrt,       [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (Ln,         [eid])        -> eidIs TCNum  ++ [EIdIsType eid TCNum]
        (Plus,       [eid1, eid2]) -> eidIs (TCEId eid1) ++ eidIs (TCEId eid2) -- ++ eidIs (TCUnion [TCNum, TCString]) -- (a -> a -> a) where a is String or Num
        (Minus,      [eid1, eid2]) -> eidIs TCNum  ++ [EIdIsType eid1 TCNum, EIdIsType eid2 TCNum]
        (Mult,       [eid1, eid2]) -> eidIs TCNum  ++ [EIdIsType eid1 TCNum, EIdIsType eid2 TCNum]
        (Div,        [eid1, eid2]) -> eidIs TCNum  ++ [EIdIsType eid1 TCNum, EIdIsType eid2 TCNum]
        (Lt,         [eid1, eid2]) -> eidIs TCBool ++ [EIdIsType eid1 TCNum, EIdIsType eid2 TCNum]
        (Mod,        [eid1, eid2]) -> eidIs TCNum  ++ [EIdIsType eid1 TCNum, EIdIsType eid2 TCNum]
        (Pow,        [eid1, eid2]) -> eidIs TCNum  ++ [EIdIsType eid1 TCNum, EIdIsType eid2 TCNum]
        (NoWidgets,  [eid])        -> eidIs (TCEId eid)
        (Explode,    [eid])        -> eidIs (TCList TCString) ++ [EIdIsType eid TCString] -- (String -> List String)
        _                          -> [EIdIsEmpty exp.val.eid "Bad operation"]
    EIf _ condExp _ thenExp _ elseExp _ ->
      eidIs (expToTC thenExp) ++ eidIs (expToTC elseExp) ++ [EIdIsType condExp.val.eid TCBool]
    ELet _ _ _ pat _ boundExp _ letBody _ ->
      -- tryMatchExpPatToPIds : Pat -> Exp -> List (PId, Exp)
      -- let
      --   pidToExp           = LangTools.tryMatchExpPatToPIds pat boundExp
      --   (matchedPIds, _)   = List.unzip pidToExp
      --   unmatchedPIds      = Utils.diffAsSet (allPIds pat) matchedPIds
      --   matchedConstraints = pidToExp |> List.map (\(pid, boundExp) -> PIdIsEId pid boundExp.val.eid)
      --   unmatchedErrors    = unmatchedPIds |> List.map (\pid -> PIdIsEmpty pid "PId didn't match in let exp")
      -- in
      gatherPatConstraints False pat ++
      [PIdIsEId pat.val.pid boundExp.val.eid] ++
      eidIs (expToTC letBody)
    ECase _ scrutinee bs _ ->
      gatherPatsConstraints True (branchPats bs) ++
      (branchPats bs |> List.map (\bPat -> PIdIsEId bPat.val.pid scrutinee.val.eid)) ++
      (branchExps bs |> List.concatMap (eidIs << expToTC))
    ETypeCase _ scrutinee bs _ ->
      [EIdIsType scrutinee.val.eid <| TCUnion (tbranchTypes bs |> List.map typeToTC)] ++
      (tbranchExps bs |> List.concatMap (eidIs << expToTC))
    EComment _ _ e1     -> eidIs (expToTC e1)
    EOption _ _ _ _ e1  -> eidIs (expToTC e1)
    ETyp _ pat tipe e _ ->
      gatherPatConstraints False pat ++
      [PIdIsType pat.val.pid (typeToTC tipe)] ++
      eidIs (expToTC e)
    EColonType _ e _ tipe _ ->
      eidIs (typeToTC tipe) ++
      eidIs (expToTC e)
    ETypeAlias _ pat tipe e _ ->
      let aliasConstraints =
        case Types.matchTypeAlias pat tipe of
          Just identToType -> identToType |> List.map (\(ident, tipe) -> TypeAlias ident (typeToTC tipe))
          Nothing          -> let _ = Debug.log "Could not match type alias" pat in [PIdIsEmpty pat.val.pid "Type alias malformed"]
      in
      aliasConstraints ++
      eidIs (expToTC e)
    EParens _ e _ _       -> eidIs (expToTC e)
    EHole _ (HoleVal val) -> val |> Types.valToMaybeType |> Maybe.map (typeToTC >> eidIs) |> Maybe.withDefault []
    EHole _ _             -> []


gatherPatsConstraints : Bool -> List Pat -> List Constraint
gatherPatsConstraints isUnion pats = List.concatMap (gatherPatConstraints isUnion) pats


-- Tuples in function pats should be interpreted strictly (isUnion false)
-- Tuples in branch cases loosely (isUnion true)
gatherPatConstraints : Bool -> Pat -> List Constraint
gatherPatConstraints isUnion pat =
  let childConstraints = gatherPatsConstraints isUnion (childPats pat) in
  childConstraints ++
  case pat.val.p__ of
    PVar _ ident _              -> [PIdVar pat.val.pid ident]
    PList _ heads _ maybeTail _ -> [PIdIsType pat.val.pid <| (if isUnion then TCTuple else TCPatTuple) (heads |> List.map (.val >> .pid >> TCPId)) (maybeTail |> Maybe.map (.val >> .pid >> TCPId))]
    PConst _ n                  -> [PIdIsType pat.val.pid TCNum]
    PBase _ (EBool _)           -> [PIdIsType pat.val.pid TCBool]
    PBase _ (EString _ _)       -> [PIdIsType pat.val.pid TCString]
    PBase _ ENull               -> [PIdIsType pat.val.pid TCNull]
    PAs _ ident _ child         -> [PIdVar pat.val.pid ident, PIdIsType pat.val.pid (TCPId child.val.pid)]
    PParens _ child _           -> [PIdIsType pat.val.pid (TCPId child.val.pid)]
    Lang.PWildcard _            -> []


-- preludeTypeGraph : TC2Graph
-- preludeTypeGraph = typecheck FastParser.prelude
