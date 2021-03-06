{-# LANGUAGE RecordWildCards #-}
module Cobalt.Core.Errors (
  Comment(..)
, NamedSolverError(..)
, SolverError(..)
, UnifyErrorReason(..)
, ErrorExplanation(..)
, AnnConstraint
, Blame
, emptySolverExplanation
, emptyUnnamedSolverExplanation
, errorFromPreviousPhase
, showErrorExplanation
) where

import Data.List (elemIndex)
import Data.Maybe (fromMaybe)
import Text.Parsec.Pos

import Cobalt.Core.Types

{-# ANN module ("HLint: ignore Use camelCase"::String) #-}

data Comment = Comment_String String
             | Comment_Pos (SourcePos, SourcePos)
             deriving (Show, Eq)

newtype NamedSolverError = NamedSolverError (Maybe String, SolverError)
data SolverError = SolverError_Unify UnifyErrorReason MonoType MonoType
                 | SolverError_Infinite TyVar MonoType
                 | SolverError_Equiv PolyType PolyType
                 | SolverError_CouldNotDischarge [Constraint]
                 | SolverError_NonTouchable [TyVar]
                 | SolverError_Inconsistency
                 | SolverError_Ambiguous TyVar [Constraint]

instance Show NamedSolverError where
  show (NamedSolverError (Nothing, e)) = show e
  show (NamedSolverError (Just m,  e)) = m ++ " ↣ " ++ show e

instance Show SolverError where
  show (SolverError_Unify r m1 m2) = "Could not unify " ++ show m1 ++ " ~ " ++ show m2 ++ " (" ++ show r ++ ")"
  show (SolverError_Infinite tv m) = "Could not construct infinite type " ++ show tv ++ " ~ " ++ show m
  show (SolverError_Equiv m1 m2) = "Could not prove equivalence between " ++ show m1 ++ " = " ++ show m2
  show (SolverError_CouldNotDischarge cs) = "Could not discharge " ++ show cs
  show (SolverError_NonTouchable vs) = "Unifying non-touchable variables " ++ show vs
  show SolverError_Inconsistency = "Inconsistent constraint found"
  show (SolverError_Ambiguous v c) = "Ambiguous type variable " ++ show v ++ " stemming from " ++ show c

data UnifyErrorReason = UnifyErrorReason_Head
                      | UnifyErrorReason_NumberOfArgs

instance Show UnifyErrorReason where
  show UnifyErrorReason_Head = "different head constructors"
  show UnifyErrorReason_NumberOfArgs = "different number of arguments"

type AnnConstraint = (Constraint,[Comment])
type Blame = [AnnConstraint]

data ErrorExplanation = SolverError { theError      :: SolverError
                                    , thePoint      :: Maybe (SourcePos, SourcePos)
                                    , theMessage    :: Maybe String
                                    , theBlame      :: Blame
                                    , theDominators :: [Constraint]
                                    }
                      | ErrorFromPreviousPhase { thePoint   :: Maybe (SourcePos, SourcePos)
                                               , theMessage :: Maybe String }

emptySolverExplanation :: NamedSolverError -> ErrorExplanation
emptySolverExplanation (NamedSolverError (msg, err)) = SolverError err Nothing msg [] []

emptyUnnamedSolverExplanation :: SolverError -> ErrorExplanation
emptyUnnamedSolverExplanation err = emptySolverExplanation (NamedSolverError (Nothing, err))

errorFromPreviousPhase :: String -> ErrorExplanation
errorFromPreviousPhase s = ErrorFromPreviousPhase Nothing (Just s)

instance Show ErrorExplanation where
  show = showErrorExplanation ""

showErrorExplanation :: String -> ErrorExplanation -> String
showErrorExplanation contents  SolverError { .. } =
    fromMaybe "Found error" theMessage
  ++ " at " ++ showPoint thePoint ++ ":\n  " ++ show theError
  ++ if null theDominators
        then ""
        else "\nwhile checking:" ++ concatMap (("\n* " ++) . show) theDominators
  ++ if null theBlame
        then ""
        else "\nstemming from:" ++ concatMap (('\n' :) . showProblem contents) theBlame
showErrorExplanation _contents ErrorFromPreviousPhase { .. } =
  "Found error at point " ++ showPoint thePoint
  ++ ":\n" ++ show theMessage

showProblem :: String -> (Constraint,[Comment]) -> String
showProblem contents (c,cms) = "* " ++ show c ++ concatMap (("\n  " ++) . showComment contents) cms

showComment :: String -> Comment -> String
showComment _ (Comment_String s)   = "since " ++ s
showComment contents (Comment_Pos (i,e)) = case (offset contents i, offset contents e) of
    (Just ioff, Just eoff) -> "from `" ++ drop ioff (take eoff contents) ++ "` "
    _ -> ""
  ++ "at " ++ showPosSmall i ++ "-" ++ showPosSmall e

showPoint :: Maybe (SourcePos, SourcePos) -> String
showPoint Nothing      = "&lt;unknown&gt;"
showPoint (Just (i,e)) = showPosSmall i ++ "-" ++ showPosSmall e

showPosSmall :: SourcePos -> String
showPosSmall s = "(" ++ show (sourceLine s) ++ "," ++ show (sourceColumn s) ++ ")"

-- From http://stackoverflow.com/questions/10473857/parsec-positions-as-offsets
offset :: String -> SourcePos -> Maybe Int
offset source pos = elemIndex pos positions
  where positions = scanl updatePosChar firstPos source
        firstPos  = initialPos (sourceName pos)
