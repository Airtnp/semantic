{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fprint-expanded-synonyms #-}

-- | This carrier interprets the Sketch effect, keeping track of
-- the current scope and in-progress graph internally.
module Control.Carrier.StackGraph
  ( StackGraphC,
    runStackGraph,
    module Control.Effect.StackGraph,
  )
where

import Analysis.Name (Name)
import qualified Analysis.Name as Name
import Control.Carrier.Fresh.Strict
import Control.Carrier.Reader
import qualified Control.Carrier.Resumable.Either as Either
import Control.Carrier.State.Strict
import Control.Effect.StackGraph
import Data.BaseError (BaseError)
import Data.Module (ModuleInfo)
import qualified Data.ScopeGraph as ScopeGraph
import Data.Semilattice.Lower
import Scope.Types
import Source.Loc (Loc)
import qualified Stack.Graph as Stack

type StackGraphC addr m =
  Either.ResumableC
    (BaseError ScopeError)
    ( StateC
        (ScopeGraph Name)
        ( StateC
            (Stack.Graph Stack.Node)
            ( StateC
                (CurrentScope Name)
                ( ReaderC
                    (Maybe Loc)
                    ( StateC
                        (Maybe Loc)
                        ( ReaderC
                            Stack.Node
                            ( ReaderC
                                ModuleInfo
                                ( FreshC m
                                )
                            )
                        )
                    )
                )
            )
        )
    )

runStackGraph ::
  (Functor m) =>
  ModuleInfo ->
  StackGraphC Name m a ->
  m (Stack.Graph Stack.Node, (ScopeGraph Name, Either (Either.SomeError (BaseError ScopeError)) a))
runStackGraph minfo go =
  evalFresh 1
    . runReader minfo
    . runReader (Stack.Scope rootname)
    . evalState Nothing
    . runReader Nothing
    . evalState (CurrentScope rootname)
    . runState @(Stack.Graph Stack.Node) initialStackGraph
    . runState @(ScopeGraph Name) initialGraph
    . Either.runResumable
    $ go
  where
    rootname = Name.nameI 0
    initialGraph = ScopeGraph.insertScope rootname lowerBound lowerBound
    initialStackGraph = Stack.scope rootname
