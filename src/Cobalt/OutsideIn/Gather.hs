{-# LANGUAGE CPP #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE PatternSynonyms #-}
module Cobalt.OutsideIn.Gather (
  Gathered(..)
, GMonad
, UseSystemFTypes(..)
, gather
) where

#if MIN_VERSION_base(4,8,0)
#else
import Control.Applicative
#endif
import Control.Lens
import Control.Monad.Except
import Control.Monad.Reader
import Data.List (partition, nub, (\\))
import Unbound.LocallyNameless

import Cobalt.Core
import Cobalt.Language
import Util.ExceptTIsFresh ()

data Gathered = Gathered { ty      :: MonoType
                         , annTerm :: TyTerm
                         , givenC  :: [Constraint]
                         , wantedC :: [Constraint]
                         } deriving Show
type GMonad = ReaderT Env (ExceptT String FreshM)

lookupFail :: (Show a, Eq a) => Lens' Env [(a,b)] -> a -> GMonad b
lookupFail p v = do place <- asks (^. p)
                    case lookup v place of
                      Nothing -> throwError $ "Cannot find " ++ show v
                      Just t  -> return t

extendEnv :: RawTermVar -> PolyType -> GMonad a -> GMonad a
extendEnv v s = local $ \(Env f d x r) -> Env ((v,s):f) d x r

extendsEnv :: [(RawTermVar, PolyType)] -> GMonad a -> GMonad a
extendsEnv v = local $ \(Env f d x r) -> Env (v ++ f) d x r

-- Phase 1: constraint gathering

data UseSystemFTypes = UseSystemFTypes | UseAnyType deriving Eq

gather :: UseSystemFTypes -> RawTerm -> GMonad Gathered
gather _ (Term_IntLiteral n _) =
  return $ Gathered MonoType_Int (Term_IntLiteral n MonoType_Int) [] []
gather _ (Term_StrLiteral s _) =
  return $ Gathered MonoType_String (Term_StrLiteral s MonoType_String) [] []
gather _ (Term_Var x _) =
  do sigma <- lookupFail fnE x
     tau <- var <$> fresh (string2Name "tau")
     return $ Gathered tau (Term_Var (translate x) tau)
                       [] [Constraint_Inst tau sigma]
gather systemf (Term_Abs b _ _) =
  do (x,e) <- unbind b
     alpha <- fresh (string2Name "alpha")
     Gathered tau annot ex c <- extendEnv x (var alpha) $ gather systemf e
     let arrow = var alpha :-->: tau
     return $ Gathered arrow (Term_Abs (bind (translate x) annot) (var alpha) arrow) ex c
gather systemf (Term_AbsAnn b _ mt@(PolyType_Mono [] m) _) = -- Case monotype
  do (x,e) <- unbind b
     Gathered tau annot ex c <- extendEnv x mt $ gather systemf e
     let arrow = m :-->: tau
     return $ Gathered arrow (Term_Abs (bind (translate x) annot) m arrow) ex c
gather systemf (Term_AbsAnn b _ t _) = -- Case polytype
  do (x,e) <- unbind b
     alpha <- fresh (string2Name "alpha")
     Gathered tau annot ex c <- extendEnv x t $ gather systemf e
     let arrow = var alpha :-->: tau
     return $ Gathered arrow (Term_AbsAnn (bind (translate x) annot) (var alpha) t arrow)
                       (ex ++ [Constraint_Equal (var alpha) t]) c
gather systemf (Term_App e1 e2 _) =
  do Gathered tau1 ann1 ex1 c1 <- gather systemf e1
     Gathered tau2 ann2 ex2 c2 <- gather systemf e2
     alpha <- var <$> fresh (string2Name "alpha")
     return $ Gathered alpha (Term_App ann1 ann2 alpha)
                       (ex1 ++ ex2)
                       (c1 ++ c2 ++ [Constraint_Unify tau1 (tau2 :-->: alpha)])
gather systemf (Term_Let b _) =
  do ((x, unembed -> e1),e2) <- unbind b
     Gathered tau1 ann1 ex1 c1 <- gather systemf e1
     Gathered tau2 ann2 ex2 c2 <- extendEnv x (PolyType_Mono [] tau1) $ gather systemf e2
     let systemFConstraint = if systemf == UseSystemFTypes then [Constraint_FType tau1] else []
     return $ Gathered tau2 (Term_Let (bind (translate x, embed ann1) ann2) tau2)
                       (ex1 ++ ex2) (systemFConstraint ++ c1 ++ c2)
gather systemf (Term_LetAnn b PolyType_Bottom a) = -- Case bottom
  gather systemf (Term_Let b a)
gather systemf (Term_LetAnn b mt@(PolyType_Mono [] m) _) = -- Case monotype
  do ((x, unembed -> e1),e2) <- unbind b
     Gathered tau1 ann1 ex1 c1 <- gather systemf e1
     Gathered tau2 ann2 ex2 c2 <- extendEnv x mt $ gather systemf e2
     return $ Gathered tau2 (Term_Let (bind (translate x, embed ann1) ann2) tau2)
                       (ex1 ++ ex2) (c1 ++ c2 ++ [Constraint_Unify tau1 m])
gather systemf (Term_LetAnn b t _) = -- Case polytype
  do ((x, unembed -> e1),e2) <- unbind b
     (q1,t1,_) <- split t
     Gathered tau1 ann1 ex1 c1 <- gather systemf e1
     Gathered tau2 ann2 ex2 c2 <- extendEnv x t $ gather systemf e2
     env <- asks (^. fnE)
     let vars = fv tau1 `union` fv c1 \\ fv env
         extra = Constraint_Exists $ bind vars (q1 ++ ex1, Constraint_Unify t1 tau1 : c1)
     return $ Gathered tau2 (Term_LetAnn (bind (translate x, embed ann1) ann2) t tau2)
                       ex2 (extra : c2)
gather systemf (Term_Match e dname bs _) =
  do Gathered tau annot ex c <- gather systemf e
     -- Work on alternatives
     tyvars <- mapM fresh =<< lookupFail dataE dname
     resultvar <- fresh $ string2Name "beta"
     alternatives <- mapM (gatherAlternative systemf dname tyvars resultvar) bs
     let allExtras = concatMap (givenC  . snd) alternatives
         allCs     = concatMap (wantedC . snd) alternatives
         bindings  = map (\((con,vars),g) -> (con, bind vars (annTerm g), var resultvar)) alternatives
         extra     = Constraint_Unify (conApply dname (map var tyvars)) tau
     return $ Gathered (var resultvar) (Term_Match annot dname bindings (var resultvar))
                       (ex ++ allExtras) (extra : c ++ allCs)

gatherAlternative :: UseSystemFTypes -> String -> [TyVar] -> TyVar -> (RawTermVar, Bind [RawTermVar] RawTerm, pos)
                  -> GMonad ((TyTermVar, [TyTermVar]), Gathered)
gatherAlternative systemf dname tyvars resultvar (con, b, _) =
  do -- Get information about constructor
     sigma <- lookupFail fnE con
     (q,arr -> (argsT,resultT'),_) <- split sigma
     let resultT = conList resultT'
     case resultT of
       (MonoType_Con dname2, convars) | dname == dname2 -> do
         (args,e) <- unbind b
         let (rest,unifs) = generateExtraUnifications tyvars convars
             argsT' = map (PolyType_Mono [] . substs unifs) argsT
         Gathered taui anni exi ci <- extendsEnv (zip args argsT') $ gather systemf e
         let extraVars  = unions (map fv argsT') \\ tyvars
             extraQs    = q ++ rest
             trivial    = all isTrivialConstraint extraQs
             withResult = Constraint_Unify taui (var resultvar) : ci
         if trivial && null extraVars
            then return ( (translate con, map translate args)
                        , Gathered taui anni exi withResult )
            else do env <- asks (^. fnE)
                    let deltai = (fv taui `union` fv ci) \\ (fv env `union` tyvars)
                        extrai = map (substs unifs) (filter (not . isTrivialConstraint) extraQs) ++ exi
                    return ( (translate con, map translate args)
                           , Gathered taui anni [] [Constraint_Exists (bind deltai (extrai,withResult))] )
       _ -> throwError $ "Match alternative " ++ show con ++ " does not correspond to data " ++ dname

generateExtraUnifications :: [TyVar] -> [MonoType] -> ([Constraint],[(TyVar,MonoType)])
generateExtraUnifications vars ms =
  let initial = zip vars ms
      (unifs, rest) = partition (\(_, m) -> case m of
                                   MonoType_Var v -> length (filter (\(_,m2) -> case m2 of
                                                                        MonoType_Var v2 -> v2 == v
                                                                        _               -> False) initial) == 1
                                   _              -> False) initial
   in (map (\(v,m) -> Constraint_Unify (var v) m) rest,
       map (\(v,MonoType_Var v2) -> (v2, var v)) unifs)

isTrivialConstraint :: Constraint -> Bool
isTrivialConstraint (Constraint_Inst _ PolyType_Bottom) = True
isTrivialConstraint (Constraint_Unify t1 t2) | t1 == t2 = True
isTrivialConstraint (Constraint_Equal t1 (PolyType_Mono [] t2)) | t1 == t2 = True
isTrivialConstraint (Constraint_Inst  t1 (PolyType_Mono [] t2)) | t1 == t2 = True
isTrivialConstraint _ = False

unions :: Eq a => [[a]] -> [a]
unions = nub . concat
