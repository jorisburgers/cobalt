{-# LANGUAGE TupleSections #-}
module Cobalt.Script.Solver (
  solve
, simpl
, SolverError(..)
, FinalSolution
) where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Data.List (union)
import Unbound.LocallyNameless hiding (union)

import Cobalt.Graph as G
import qualified Cobalt.OutsideIn.Solver as OIn
import Cobalt.OutsideIn.Solver (SolverError(..))
import Cobalt.Script.Script
import Cobalt.Types

type OInState = ([Constraint],[Constraint],[TyVar])
-- First is a consistent solution
-- Second, the list of errors found
-- Third, the graph of constraints
type ScriptSolution = (OInState, [SolverError], Graph)
type FinalSolution  = (OIn.Solution, [SolverError], Graph)

solve :: [Axiom] -> [Constraint] -> [TyVar] -> TyScript
      -> FreshM FinalSolution
solve ax g tch w = do
  (((simplG,rs,vars),err,graph), extraExists) <- simpl ax g tch w
  let s@(OIn.Solution _simplG' rs' subst' _vars') = OIn.toSolution simplG rs vars
  solveImpl ax (g ++ rs') (map (substsScript subst') extraExists) (s,err,graph)

solveImpl :: [Axiom] -> [Constraint] -> [TyScript]
          -> FinalSolution -> FreshM FinalSolution
solveImpl _ _ [] sol = return sol
solveImpl ax g (Exists vars q c : rest) (curSol, currErr, currGraph) = do
  (thisSol, thisErr, thisGraph) <- solve ax (g ++ q) vars c
  let newGraph = mappend thisGraph currGraph -- : map (\x -> singletonNode _ x "exists") (q ++ c)
  case (thisSol, thisErr) of
    (OIn.Solution _ [] _ _, []) -> solveImpl ax g rest (curSol, currErr, newGraph)
    _ -> solveImpl ax g rest (curSol, OIn.SolverError_CouldNotDischarge (toConstraintList' c) : (currErr ++ thisErr), newGraph)
solveImpl _ _ _ _ = error "This should never happen"
      
-- Solve one layer of constraints
-- and return the list of extra Exists.
simpl :: [Axiom] -> [Constraint] -> [TyVar] -> TyScript
      -> FreshM (ScriptSolution, [TyScript])
simpl _ g tch Empty =
  return ((emptySolution g tch, [], G.empty), [])
simpl _ g tch me@(Exists _ _ _) =
  return ((emptySolution g tch, [], G.empty), [me])
simpl ax g tch (Singleton c _) = do
  solved <- simplMany' ax [((g,[c],tch),[],G.empty)]
  case solved of
    (Left err, _)    -> return ((emptySolution g tch, [err], G.empty), [])
    (Right s, graph) -> return ((s, [], graph), [])
simpl ax g tch (Merge lst _) = do
  simpls <- mapM (simpl ax g tch) lst
  let (results, exs) = unzip simpls
      errs = map (\(_,e,_) -> e) results
  solved <- simplMany' ax results
  case solved of
    (Left err, _) ->
       -- Should be changed to use an heuristic
       let (fstSol, _, fstGraph) = head results
        in return ((fstSol, err : concat errs, fstGraph), concat exs)
    (Right s, graph) -> return ((s, concat errs, graph), concat exs)
simpl ax g tch (Asym s1 s2 info) = simpl ax g tch (Merge [s2,s1] info)


-- All the rest of this file is just converting back and forth
-- the OutsideIn representation and the Script representation
emptySolution :: [Constraint] -> [TyVar] -> OInState
emptySolution g tch = (g, [], tch)

-- Adapter for multiple OutsideIn solver
simplMany' :: [Axiom] -> [ScriptSolution]
           -> FreshM (Either SolverError OInState, Graph)
simplMany' ax lst =
  let given  = unions $ map (\((g,_,_),_,_) -> g) lst
      wanted = unions $ map (\((_,w,_),_,_) -> w) lst
      tch    = unions $ map (\((_,_,t),_,_) -> t) lst
      graphs = map (\(_,_,g) -> g) lst
   in runWriterT $
        runExceptT $
          flip runReaderT ax $
            flip evalStateT tch $ do
              mapM_ tell graphs
              OIn.simpl given wanted

unions :: Eq a => [[a]] -> [a]
unions = foldr union []
