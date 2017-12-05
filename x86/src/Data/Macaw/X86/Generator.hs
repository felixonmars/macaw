{-
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>, Simon Winwood <sjw@galois.com>

This defines the monad @X86Generator@, which provides operations for
modeling X86 semantics.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
module Data.Macaw.X86.Generator
  ( -- * X86Generator
    X86Generator(..)
  , runX86Generator
  , X86GCont
  , addStmt
  , addArchStmt
  , addArchTermStmt
  , evalArchFn
  , evalAssignRhs
  , shiftX86GCont
    -- * GenResult
  , GenResult(..)
  , finishBlock
    -- * PreBlock
  , PreBlock
  , emptyPreBlock
  , pBlockIndex
  , pBlockState
  , pBlockStmts
  , pBlockApps
  , finishBlock'
    -- * Misc
  , BlockSeq(..)
  , nextBlockID
  , frontierBlocks
    -- * GenState
  , GenState(..)
  , mkGenResult
  , blockSeq
  , blockState
  , curX86State
    -- * Expr
  , Expr(..)
  , app
  , asApp
  , asArchFn
  , asBoolLit
  , asBVLit
  , eval
  , getRegValue
  , setReg
  , incAddr
  ) where

import           Control.Lens
import           Control.Monad.Cont
import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.ST
import           Control.Monad.State.Strict
import           Data.Bits
import           Data.Foldable
import           Data.Macaw.CFG.App
import           Data.Macaw.CFG.Block
import           Data.Macaw.CFG.Core
import           Data.Macaw.Memory
import           Data.Macaw.Types
import           Data.Maybe
import           Data.Parameterized.Classes
import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.Nonce
import           Data.Parameterized.TraversableFC
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Word

import           Data.Macaw.X86.ArchTypes
import           Data.Macaw.X86.X86Reg

------------------------------------------------------------------------
-- Expr

-- | A pure expression for isValue.
data Expr ids tp where
  -- An expression obtained from some value.
  ValueExpr :: !(Value X86_64 ids tp) -> Expr ids tp
  -- An expression that is computed from evaluating subexpressions.
  AppExpr :: !(App (Expr ids) tp) -> Expr ids tp

instance Show (Expr ids tp) where
  show (ValueExpr v) = show v
  show AppExpr{} = "app"

instance ShowF (Expr ids)

instance Eq (Expr ids tp) where
  (==) = \x y -> isJust (testEquality x y)

instance TestEquality (Expr ids) where
  testEquality (ValueExpr x) (ValueExpr y) = do
    Refl <- testEquality x y
    return Refl
  testEquality (AppExpr x) (AppExpr y) = do
    Refl <- testEquality x y
    return Refl
  testEquality _ _ = Nothing

instance HasRepr (Expr ids) TypeRepr where
  typeRepr (ValueExpr v) = typeRepr v
  typeRepr (AppExpr a) = typeRepr a

asApp :: Expr ids tp -> Maybe (App (Expr ids) tp)
asApp (AppExpr   a) = Just a
asApp (ValueExpr v) = fmapFC ValueExpr <$> valueAsApp v

asArchFn :: Expr ids tp -> Maybe (X86PrimFn (Value X86_64 ids) tp)
asArchFn (ValueExpr (AssignedValue (Assignment _ (EvalArchFn a _)))) = Just a
asArchFn _ = Nothing

app :: App (Expr ids) tp -> Expr ids tp
app = AppExpr

asBoolLit :: Expr ids BoolType -> Maybe Bool
asBoolLit (ValueExpr (BoolValue b)) = Just b
asBoolLit _ = Nothing

asBVLit :: Expr ids (BVType w) -> Maybe Integer
asBVLit (ValueExpr (BVValue _ v)) = Just v
asBVLit _ = Nothing

------------------------------------------------------------------------
-- PreBlock

-- | A block that we have not yet finished.
data PreBlock ids = PreBlock { pBlockIndex :: !Word64
                             , pBlockAddr  :: !(MemSegmentOff 64)
                               -- ^ Starting address of function in preblock.
                             , _pBlockStmts :: !(Seq (Stmt X86_64 ids))
                             , _pBlockState :: !(RegState X86Reg (Value X86_64 ids))
                             , _pBlockApps  :: !(MapF (App (Value X86_64 ids)) (Assignment X86_64 ids))
                             }

-- | Create a new pre block.
emptyPreBlock :: RegState X86Reg (Value X86_64 ids)
              -> Word64
              -> MemSegmentOff 64
              -> PreBlock ids
emptyPreBlock s idx addr =
  PreBlock { pBlockIndex  = idx
           , pBlockAddr   = addr
           , _pBlockStmts = Seq.empty
           , _pBlockApps  = MapF.empty
           , _pBlockState = s
           }

pBlockStmts :: Simple Lens (PreBlock ids) (Seq (Stmt X86_64 ids))
pBlockStmts = lens _pBlockStmts (\s v -> s { _pBlockStmts = v })

pBlockState :: Simple Lens (PreBlock ids) (RegState X86Reg (Value X86_64 ids))
pBlockState = lens _pBlockState (\s v -> s { _pBlockState = v })

pBlockApps  :: Simple Lens (PreBlock ids) (MapF (App (Value X86_64 ids)) (Assignment X86_64 ids))
pBlockApps = lens _pBlockApps (\s v -> s { _pBlockApps = v })

-- | Finishes the current block, if it is started.
finishBlock' :: PreBlock ids
             -> (RegState X86Reg (Value X86_64 ids) -> TermStmt X86_64 ids)
             -> Block X86_64 ids
finishBlock' pre_b term =
  Block { blockLabel = pBlockIndex pre_b
        , blockStmts = toList (pre_b^.pBlockStmts)
        , blockTerm  = term (pre_b^.pBlockState)
        }

------------------------------------------------------------------------
-- BlockSeq

-- | List of blocks generated so far, and an index for generating new block labels.
data BlockSeq ids  = BlockSeq
       { _nextBlockID  :: !Word64
         -- ^ Index of next block
       , _frontierBlocks :: !(Seq (Block X86_64 ids))
         -- ^ Blocks added to CFG
       }

-- | Control flow blocs generated so far.
nextBlockID :: Simple Lens (BlockSeq ids) Word64
nextBlockID = lens _nextBlockID (\s v -> s { _nextBlockID = v })

-- | Blocks that are not in CFG that end with a FetchAndExecute,
-- which we need to analyze to compute new potential branch targets.
frontierBlocks :: Simple Lens (BlockSeq ids) (Seq (Block X86_64 ids))
frontierBlocks = lens _frontierBlocks (\s v -> s { _frontierBlocks = v })

------------------------------------------------------------------------
-- GenResult

-- | The final result from the block generator.
data GenResult ids = GenResult { resBlockSeq :: !(BlockSeq ids)
                               , resState :: !(Maybe (PreBlock ids))
                               }

-- | Finishes the current block, if it is started.
finishBlock :: (RegState X86Reg (Value X86_64 ids) -> TermStmt X86_64 ids)
            -> GenResult ids
            -> BlockSeq ids
finishBlock term st =
  case resState st of
    Nothing    -> resBlockSeq st
    Just pre_b ->
      let b = finishBlock' pre_b term
       in seq b $ resBlockSeq st & frontierBlocks %~ (Seq.|> b)

------------------------------------------------------------------------
-- GenState

-- | A state used for the block generator.
data GenState st_s ids = GenState
       { assignIdGen   :: !(NonceGenerator (ST st_s) ids)
         -- ^ 'NonceGenerator' for generating 'AssignId's
       , _blockSeq     :: !(BlockSeq ids)
         -- ^ Blocks generated so far.
       , _blockState   :: !(PreBlock ids)
         -- ^ Current block
       , genAddr      :: !(MemSegmentOff 64)
         -- ^ Address of instruction we are translating
       , genMemory    :: !(Memory 64)
       }

-- | Create a gen result from a state result.
mkGenResult :: GenState st_s ids -> GenResult ids
mkGenResult s = GenResult { resBlockSeq = s^.blockSeq
                          , resState = Just (s^.blockState)
                          }

-- | Control flow blocs generated so far.
blockSeq :: Simple Lens (GenState st_s ids) (BlockSeq ids)
blockSeq = lens _blockSeq (\s v -> s { _blockSeq = v })

-- | Blocks that are not in CFG that end with a FetchAndExecute,
-- which we need to analyze to compute new potential branch targets.
blockState :: Lens (GenState st_s ids) (GenState st_s ids) (PreBlock ids) (PreBlock ids)
blockState = lens _blockState (\s v -> s { _blockState = v })

curX86State :: Simple Lens (GenState st_s ids) (RegState X86Reg (Value X86_64 ids))
curX86State = blockState . pBlockState

------------------------------------------------------------------------
-- X86Generator

-- | X86Generator is used to construct basic blocks from a stream of instructions
-- using the semantics.
--
-- It is implemented as a state monad in a continuation passing style so that
-- we can perform symbolic branches.
--
-- This returns either a failure message or the next state.
newtype X86Generator st_s ids a =
  X86G { unX86G ::
           ContT (GenResult ids)
                 (ReaderT (GenState st_s ids)
                          (ExceptT Text (ST st_s))) a
       }
  deriving (Applicative, Functor)

-- The main reason for this definition to be given explicitly is so that fail
-- uses throwError instead of the underlying fail in ST
instance Monad (X86Generator st_s ids) where
  return v = seq v $ X86G $ return v
  (X86G m) >>= h = X86G $ m >>= \v -> seq v (unX86G (h v))
  X86G m >> X86G n = X86G $ m >> n
  fail msg = seq t $ X86G $ ContT $ \_ -> throwError t
    where t = Text.pack msg

-- | The type of an 'X86Generator' continuation
type X86GCont st_s ids a
  =  a
  -> GenState st_s ids
  -> ExceptT Text (ST st_s) (GenResult ids)

-- | Run an 'X86Generator' starting from a given state
runX86Generator :: X86GCont st_s ids a
                -> GenState st_s ids
                -> X86Generator st_s ids a
                -> ExceptT Text (ST st_s) (GenResult ids)
runX86Generator k st (X86G m) = runReaderT (runContT m (ReaderT . k)) st

-- | Capture the current continuation and 'GenState' in an 'X86Generator'
shiftX86GCont :: (X86GCont st_s ids a
                  -> GenState st_s ids
                  -> ExceptT Text (ST st_s) (GenResult ids))
              -> X86Generator st_s ids a
shiftX86GCont f =
  X86G $ ContT $ \k -> ReaderT $ \s -> f (runReaderT . k) s

getState :: X86Generator st_s ids (GenState st_s ids)
getState = X86G ask

modGenState :: State (GenState st_s ids) a -> X86Generator st_s ids a
modGenState m = X86G $ ContT $ \c -> ReaderT $ \s ->
  let (a,s') = runState m s
   in runReaderT (c a) s'

-- | Return the value associated with the given register.
getRegValue :: X86Reg tp -> X86Generator st_s ids (Value X86_64 ids tp)
getRegValue r = view (curX86State . boundValue r) <$> getState

-- | Set the value associated with the given register.
setReg :: X86Reg tp -> Value X86_64 ids tp -> X86Generator st_s ids ()
setReg r v = modGenState $ curX86State . boundValue r .= v

-- | Add a statement to the list of statements.
addStmt :: Stmt X86_64 ids -> X86Generator st_s ids ()
addStmt stmt = seq stmt $
  modGenState $ blockState . pBlockStmts %= (Seq.|> stmt)

addArchStmt :: X86Stmt (Value X86_64 ids) -> X86Generator st_s ids ()
addArchStmt = addStmt . ExecArchStmt

-- | execute a primitive instruction.
addArchTermStmt :: X86TermStmt ids -> X86Generator st ids ()
addArchTermStmt ts = do
  shiftX86GCont $ \_ s0 -> do
    -- Get last block.
    let p_b = s0 ^. blockState
    -- Create finished block.
    let fin_b = finishBlock' p_b $ ArchTermStmt ts
    seq fin_b $ do
    -- Return early
    return $ GenResult { resBlockSeq = s0 ^.blockSeq & frontierBlocks %~ (Seq.|> fin_b)
                       , resState = Nothing
                       }

-- | Create a new assignment identifier
newAssignID :: X86Generator st_s ids (AssignId ids tp)
newAssignID = do
  gs <- getState
  liftM AssignId $ X86G $ lift $ lift $ lift $ freshNonce $ assignIdGen gs

addAssignment :: AssignRhs X86_64 (Value X86_64 ids) tp
              -> X86Generator st_s ids (Assignment X86_64 ids tp)
addAssignment rhs = do
  l <- newAssignID
  let a = Assignment l rhs
  addStmt $ AssignStmt a
  pure $! a

evalAssignRhs :: AssignRhs X86_64 (Value X86_64 ids) tp
              -> X86Generator st_s ids (Expr ids tp)
evalAssignRhs rhs =
  ValueExpr . AssignedValue <$> addAssignment rhs

-- | Evaluate an architecture-specific function and return the resulting expr.
evalArchFn :: X86PrimFn (Value X86_64 ids) tp
          -> X86Generator st_s ids (Expr ids tp)
evalArchFn f = evalAssignRhs (EvalArchFn f (typeRepr f))


------------------------------------------------------------------------
-- Evaluate expression

-- | This function does a top-level constant propagation/constant reduction.
-- We assume that the leaf nodes have also been propagated (i.e., we only operate
-- at the outermost term)
constPropagate :: forall ids tp. App (Value X86_64 ids) tp -> Maybe (Value X86_64 ids tp)
constPropagate v =
  case v of
   BVAnd _ l r
     | Just _ <- testEquality l r -> Just l
   BVAnd sz l r                   -> binop (.&.) sz l r
   -- Units
   BVAdd _  l (BVValue _ 0)       -> Just l
   BVAdd _  (BVValue _ 0) r       -> Just r
   BVAdd sz l r                   -> binop (+) sz l r
   BVMul _  l (BVValue _ 1)       -> Just l
   BVMul _  (BVValue _ 1) r       -> Just r

   UExt  (BVValue _ n) sz         -> Just $ mkLit sz n

   -- Word operations
   Trunc (BVValue _ x) sz         -> Just $ mkLit sz x

   -- Boolean operations
   BVUnsignedLt l r               -> boolop (<) l r
   Eq l r                         -> boolop (==) l r
   BVComplement sz x              -> unop complement sz x
   _                              -> Nothing
  where
    boolop :: (Integer -> Integer -> Bool)
           -> Value X86_64 ids utp
           -> Value X86_64 ids utp
           -> Maybe (Value X86_64 ids BoolType)
    boolop f (BVValue _ l) (BVValue _ r) = Just $ BoolValue (f l r)
    boolop _ _ _ = Nothing

    unop :: (tp ~ BVType n)
         => (Integer -> Integer)
         -> NatRepr n -> Value X86_64 ids tp -> Maybe (Value X86_64 ids tp)
    unop f sz (BVValue _ l)  = Just $ mkLit sz (f l)
    unop _ _ _               = Nothing

    binop :: (tp ~ BVType n) => (Integer -> Integer -> Integer)
          -> NatRepr n
          -> Value X86_64 ids tp
          -> Value X86_64 ids tp
          -> Maybe (Value X86_64 ids tp)
    binop f sz (BVValue _ l) (BVValue _ r) = Just $ mkLit sz (f l r)
    binop _ _ _ _                          = Nothing

evalApp :: App (Value X86_64 ids) tp -> X86Generator st_s ids (Value X86_64 ids tp)
evalApp a = do
  case constPropagate a of
    Nothing -> do
      s <- getState
      case MapF.lookup a (s^.blockState^.pBlockApps) of
        Nothing -> do
          r <- addAssignment (EvalApp a)
          modGenState $ blockState . pBlockApps %= MapF.insert a r
          return (AssignedValue r)
        Just r -> return (AssignedValue r)
    Just v  -> return v


eval :: Expr ids tp -> X86Generator st_s ids (Value X86_64 ids tp)
eval (ValueExpr v) = return v
eval (AppExpr a) = evalApp =<< traverseFC eval a
