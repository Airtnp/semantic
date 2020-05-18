{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Language.Python.ScopeGraph
  ( scopeGraphModule,
  )
where

import AST.Element
import qualified Analysis.Name as Name
import Control.Effect.StackGraph
import qualified Control.Effect.StackGraph.Properties.Declaration as Props
import qualified Control.Effect.StackGraph.Properties.Reference as Props
import Control.Effect.State
import Control.Lens ((^.))
import Data.Foldable
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Monoid
import qualified Data.ScopeGraph as ScopeGraph
import qualified Data.Text as Text
import GHC.Records
import GHC.TypeLits
import qualified Language.Python.AST as Py
import Language.Python.Patterns
import Scope.Graph.Convert (Result (..), complete, todo)
import Scope.Types as Scope
import Source.Loc (Loc)
import Source.Span (Pos (..), Span, point, span_)
import qualified Stack.Graph as Stack

-- This typeclass is internal-only, though it shares the same interface
-- as the one defined in semantic-scope-graph. The somewhat-unconventional
-- quantified constraint is to avoid having to define Show1 instances for
-- every single Python AST type.
class (forall a. Show a => Show (t a)) => ToScopeGraph t where
  scopeGraph ::
    ( StackGraphEff sig m,
      Monoid (m Result)
    ) =>
    t Loc ->
    m Result

instance (ToScopeGraph l, ToScopeGraph r) => ToScopeGraph (l :+: r) where
  scopeGraph (L1 l) = scopeGraph l
  scopeGraph (R1 r) = scopeGraph r

onField ::
  forall (field :: Symbol) syn sig m r.
  ( StackGraphEff sig m,
    HasField field (r Loc) (syn Loc),
    ToScopeGraph syn,
    Monoid (m Result)
  ) =>
  r Loc ->
  m Result
onField =
  scopeGraph @syn
    . getField @field

onChildren ::
  ( Traversable t,
    ToScopeGraph syn,
    StackGraphEff sig m,
    HasField "extraChildren" (r Loc) (t (syn Loc)),
    Monoid (m Result)
  ) =>
  r Loc ->
  m Result
onChildren =
  fmap fold
    . traverse scopeGraph
    . getField @"extraChildren"

scopeGraphModule :: StackGraphEff sig m => Py.Module Loc -> m Result
scopeGraphModule = getAp . scopeGraph

instance ToScopeGraph Py.AssertStatement where scopeGraph = onChildren

instance ToScopeGraph Py.Assignment where
  scopeGraph (Py.Assignment ann (SingleIdentifier t) val _typ) = do
    -- declare
    --   t
    --   Props.Declaration
    --     { Props.kind = ScopeGraph.Assignment,
    --       Props.relation = ScopeGraph.Default,
    --       Props.associatedScope = Nothing,
    --       Props.span = ann ^. span_
    --     }
    -- maybe complete scopeGraph val
    todo "Plz implement ScopeGraph.hs l110"
  scopeGraph x = todo x

instance ToScopeGraph Py.Await where
  scopeGraph (Py.Await _ a) = scopeGraph a

instance ToScopeGraph Py.BooleanOperator where
  scopeGraph (Py.BooleanOperator _ _ left right) = scopeGraph left <> scopeGraph right

instance ToScopeGraph Py.BinaryOperator where
  scopeGraph (Py.BinaryOperator _ _ left right) = scopeGraph left <> scopeGraph right

instance ToScopeGraph Py.AugmentedAssignment where scopeGraph = onField @"right"

instance ToScopeGraph Py.Attribute where scopeGraph = todo

instance ToScopeGraph Py.Block where scopeGraph = onChildren

instance ToScopeGraph Py.BreakStatement where scopeGraph = mempty

instance ToScopeGraph Py.Call where
  scopeGraph
    Py.Call
      { function,
        arguments = L1 Py.ArgumentList {extraChildren = args}
      } = do
      result <- scopeGraph function
      let scopeGraphArg = \case
            Prj expr -> scopeGraph @Py.Expression expr
            other -> todo other
      args <- traverse scopeGraphArg args
      pure (result <> mconcat args)
  scopeGraph it = todo it

instance ToScopeGraph Py.ClassDefinition where scopeGraph = todo

instance ToScopeGraph Py.ConcatenatedString where scopeGraph = mempty

deriving instance ToScopeGraph Py.CompoundStatement

instance ToScopeGraph Py.ConditionalExpression where scopeGraph = onChildren

instance ToScopeGraph Py.ContinueStatement where scopeGraph = mempty

instance ToScopeGraph Py.DecoratedDefinition where scopeGraph = todo

instance ToScopeGraph Py.ComparisonOperator where scopeGraph = onChildren

instance ToScopeGraph Py.DeleteStatement where scopeGraph = mempty

instance ToScopeGraph Py.Dictionary where scopeGraph = onChildren

instance ToScopeGraph Py.DictionaryComprehension where scopeGraph = todo

instance ToScopeGraph Py.DictionarySplat where scopeGraph = todo

deriving instance ToScopeGraph Py.Expression

instance ToScopeGraph Py.ElseClause where scopeGraph = onField @"body"

instance ToScopeGraph Py.ElifClause where
  scopeGraph (Py.ElifClause _ body condition) = scopeGraph condition <> scopeGraph body

instance ToScopeGraph Py.Ellipsis where scopeGraph = mempty

instance ToScopeGraph Py.ExceptClause where scopeGraph = onChildren

instance ToScopeGraph Py.ExecStatement where scopeGraph = mempty

instance ToScopeGraph Py.ExpressionStatement where scopeGraph = onChildren

instance ToScopeGraph Py.ExpressionList where scopeGraph = onChildren

instance ToScopeGraph Py.False where scopeGraph _ = pure mempty

instance ToScopeGraph Py.FinallyClause where scopeGraph = onField @"extraChildren"

instance ToScopeGraph Py.Float where scopeGraph = mempty

instance ToScopeGraph Py.ForStatement where scopeGraph = todo

instance ToScopeGraph Py.FunctionDefinition where
  scopeGraph
    Py.FunctionDefinition
      { ann,
        name = Py.Identifier _ann1 name,
        parameters = Py.Parameters _ann2 parameters,
        body
      } = do
      let name' = Name.name name

      CurrentScope currentScope' <- currentScope
      let declaration = (Stack.Declaration name' ScopeGraph.Function ann)
      modify (Stack.addEdge (Stack.Scope currentScope') declaration)
      modify (Stack.addEdge declaration (Stack.PopSymbol "()"))

      let declProps =
            Props.Declaration
              { Props.kind = ScopeGraph.Parameter,
                Props.relation = ScopeGraph.Default,
                Props.associatedScope = Nothing,
                Props.span = point (Pos 0 0)
              }
      let param (Py.Parameter (Prj (Py.Identifier pann pname))) = (pann, Name.name pname)
          param _ = error "Plz implement ScopeGraph.hs l223"
      let parameterMs = fmap param parameters

      -- Add the formal parameters scope pointing to each of the parameter nodes
      let formalParametersScope = Stack.Scope (Name.name "FormalParameters")
      for_ (zip [0 ..] parameterMs) $ \(ix, (pos, parameter)) -> do
        paramNode <- declareParameter parameter ix ScopeGraph.Parameter pos
        modify (Stack.addEdge formalParametersScope paramNode)

      -- Add the parent scope pointing to the formal parameters node
      let parentScopeName = Name.name (Text.pack "ParentScope " <> name)
          parentScope = Stack.ParentScope parentScopeName
      modify (Stack.addEdge parentScope formalParametersScope)

      -- Convert the body, using the parent scope name as the root scope
      res <- withScope parentScopeName $ scopeGraph body
      let callNode = Stack.PopSymbol "()"
      case (res :: Result) of
        ReturnNodes nodes -> do
          for_ nodes $ \node ->
            modify (Stack.addEdge callNode node)
        _ -> pure ()

      -- Add the scope that contains the declared function name
      (functionNameNode, associatedScope) <-
        declareFunction
          (Just name')
          ScopeGraph.Function
          ann

      modify (Stack.addEdge functionNameNode callNode)

      pure (ReturnNodes [])

instance ToScopeGraph Py.FutureImportStatement where scopeGraph = todo

instance ToScopeGraph Py.GeneratorExpression where scopeGraph = todo

instance ToScopeGraph Py.Identifier where
  -- TODO: Should Py.Identifier mutate state?
  scopeGraph = todo

instance ToScopeGraph Py.IfStatement where
  scopeGraph (Py.IfStatement _ alternative body condition) =
    scopeGraph condition
      <> scopeGraph body
      <> foldMap scopeGraph alternative

instance ToScopeGraph Py.GlobalStatement where scopeGraph = todo

instance ToScopeGraph Py.Integer where scopeGraph = mempty

instance ToScopeGraph Py.ImportStatement where
  scopeGraph (Py.ImportStatement _ ((R1 (Py.DottedName _ names@((Py.Identifier ann definition) :| _))) :| [])) = do
    rootScope' <- rootScope
    ScopeGraph.CurrentScope previousScope <- currentScope

    name <- Name.gensym

    let names' = (\(Py.Identifier ann name) -> (Name.name name, Identifier, ann)) <$> names
    childGraph <- addDeclarations names'
    let childGraph' = Stack.addEdge (Stack.Scope name) (Stack.Declaration (Name.name definition) Identifier ann) childGraph
    let childGraph'' = Stack.addEdge ((\(name, kind, ann) -> Stack.Reference name kind ann) (NonEmpty.head names')) rootScope' childGraph'

    modify (Stack.addEdge (Stack.Scope name) (Stack.Scope previousScope) . Stack.overlay childGraph'')

    putCurrentScope name

    complete
  scopeGraph term = todo (show term)

instance ToScopeGraph Py.ImportFromStatement where
  -- TODO: Implement this
  scopeGraph term@(Py.ImportFromStatement _ [] (L1 (Py.DottedName _ names)) (Just (Py.WildcardImport _ _))) = todo term
  scopeGraph (Py.ImportFromStatement _ imports (L1 (Py.DottedName _ names@((Py.Identifier ann scopeName) :| _))) Nothing) = do
    -- let toName (Py.Identifier _ name) = Name.name name
    -- newEdge ScopeGraph.Import (toName <$> names)

    -- let referenceProps = Props.Reference ScopeGraph.Identifier ScopeGraph.Default (ann ^. span_ :: Span)
    -- newReference (Name.name scopeName) referenceProps

    -- let pairs = zip (toList names) (tail $ toList names)
    -- for_ pairs $ \pair -> do
    --   case pair of
    --     (scopeIdentifier, referenceIdentifier@(Py.Identifier ann2 _)) -> do
    --       withScope (toName scopeIdentifier) $ do
    --         let referenceProps = Props.Reference ScopeGraph.Identifier ScopeGraph.Default (ann2 ^. span_ :: Span)
    --         newReference (toName referenceIdentifier) referenceProps

    -- completions <- for imports $ \identifier -> do
    --   case identifier of
    --     (R1 (Py.DottedName _ (Py.Identifier ann name :| []))) -> do
    --       let referenceProps = Props.Reference ScopeGraph.Identifier ScopeGraph.Default (ann ^. span_ :: Span)
    --       complete <* newReference (Name.name name) referenceProps
    --     (L1 (Py.AliasedImport _ (Py.Identifier ann name) (Py.DottedName _ (Py.Identifier ann2 ref :| _)))) -> do
    --       let declProps = Props.Declaration ScopeGraph.UnqualifiedImport ScopeGraph.Default Nothing (ann ^. span_ :: Span)
    --       declare (Name.name name) declProps

    --       let referenceProps = Props.Reference ScopeGraph.Identifier ScopeGraph.Default (ann2 ^. span_ :: Span)
    --       newReference (Name.name ref) referenceProps

    --       complete
    --     (R1 (Py.DottedName _ ((Py.Identifier _ _) :| (_ : _)))) -> undefined

    -- pure (mconcat completions)
    todo "Plz implement: ScopeGraph.hs l321"
  scopeGraph term = todo term

instance ToScopeGraph Py.Lambda where scopeGraph = todo

instance ToScopeGraph Py.List where scopeGraph = onChildren

instance ToScopeGraph Py.ListComprehension where scopeGraph = todo

instance ToScopeGraph Py.ListSplat where scopeGraph = onChildren

instance ToScopeGraph Py.NamedExpression where scopeGraph = todo

instance ToScopeGraph Py.None where scopeGraph = mempty

instance ToScopeGraph Py.NonlocalStatement where scopeGraph = todo

instance ToScopeGraph Py.Module where
  scopeGraph term@(Py.Module ann _) = do
    rootScope' <- rootScope

    putCurrentScope "__main__"

    modify (Stack.addEdge rootScope' (Stack.Declaration "__main__" Identifier ann))

    res <- onChildren term

    newGraph <- get @(Stack.Graph Stack.Node)

    ScopeGraph.CurrentScope currentName <- currentScope
    modify (Stack.addEdge (Stack.Declaration "__main__" Identifier ann) (Stack.Scope currentName) . Stack.overlay newGraph)

    pure res

instance ToScopeGraph Py.ReturnStatement where
  scopeGraph (Py.ReturnStatement _ val) = do
    case val of
      Just mVal -> do
        res <- scopeGraph mVal
        case res of
          ValueNode node -> do
            modify (Stack.addEdge (Stack.Scope "R") node)
            pure (ReturnNodes [Stack.Scope "R"])
          _ -> pure Complete
      Nothing -> pure Complete

instance ToScopeGraph Py.True where scopeGraph = mempty

instance ToScopeGraph Py.NotOperator where scopeGraph = onField @"argument"

instance ToScopeGraph Py.Pair where
  scopeGraph (Py.Pair _ value key) = scopeGraph key <> scopeGraph value

instance ToScopeGraph Py.ParenthesizedExpression where scopeGraph = onField @"extraChildren"

instance ToScopeGraph Py.PassStatement where scopeGraph = mempty

instance ToScopeGraph Py.PrintStatement where
  scopeGraph (Py.PrintStatement _ args _chevron) = foldMap scopeGraph args

deriving instance ToScopeGraph Py.PrimaryExpression

deriving instance ToScopeGraph Py.SimpleStatement

instance ToScopeGraph Py.RaiseStatement where scopeGraph = todo

instance ToScopeGraph Py.Set where scopeGraph = onChildren

instance ToScopeGraph Py.SetComprehension where scopeGraph = todo

instance ToScopeGraph Py.String where scopeGraph = mempty

instance ToScopeGraph Py.Subscript where scopeGraph = todo

instance ToScopeGraph Py.Tuple where scopeGraph = onChildren

instance ToScopeGraph Py.TryStatement where
  scopeGraph (Py.TryStatement _ body elseClauses) =
    scopeGraph body
      <> foldMap scopeGraph elseClauses

instance ToScopeGraph Py.UnaryOperator where scopeGraph = onField @"argument"

instance ToScopeGraph Py.WhileStatement where
  scopeGraph Py.WhileStatement {alternative, body, condition} =
    scopeGraph condition
      <> scopeGraph body
      <> foldMap scopeGraph alternative

instance ToScopeGraph Py.WithStatement where
  scopeGraph = todo

instance ToScopeGraph Py.Yield where scopeGraph = onChildren
