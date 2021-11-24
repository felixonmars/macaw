-- | Provides functions used to identify calls and returns in the instructions.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}

module Data.Macaw.ARM.Identify
    ( identifyCall
    , identifyReturn
    , isReturnValue
    , conditionalReturnClassifier
    ) where

import           Control.Applicative ( (<|>) )
import           Control.Lens ( (^.) )
import           Control.Monad ( when )
import qualified Control.Monad.Reader as CMR
import qualified Data.Foldable as F
import qualified Data.Macaw.ARM.ARMReg as AR
import qualified Data.Macaw.ARM.Arch as Arch
import qualified Data.Macaw.AbsDomain.AbsState as MA
import qualified Data.Macaw.AbsDomain.JumpBounds as Jmp
import qualified Data.Macaw.Architecture.Info as MAI
import qualified Data.Macaw.CFG as MC
import qualified Data.Macaw.Discovery.Classifier as MDC
import qualified Data.Macaw.Discovery.ParsedContents as Parsed
import qualified Data.Macaw.Memory as MM
import qualified Data.Macaw.Memory.Permissions as MMP
import qualified Data.Macaw.SemMC.Simplify as MSS
import qualified Data.Macaw.Types as MT
import qualified Data.Sequence as Seq

import qualified SemMC.Architecture.AArch32 as ARM

import Prelude

-- | Test if an address is in an executable segment
isExecutableSegOff :: MC.MemSegmentOff w -> Bool
isExecutableSegOff sa =
  MC.segmentFlags (MC.segoffSegment sa) `MMP.hasPerm` MMP.execute

-- | Identifies a call statement, *after* the corresponding statement
-- has been performed.  This can be tricky with ARM because there are
-- several instructions that can update R15 and effect a "call",
-- athough the predicate condition on those instructions can determine
-- if it is actually executed or not.  Also need to consider A32
-- v.s. T32 mode.
identifyCall :: MM.Memory (MC.ArchAddrWidth ARM.AArch32)
             -> Seq.Seq (MC.Stmt ARM.AArch32 ids)
             -> MC.RegState (MC.ArchReg ARM.AArch32) (MC.Value ARM.AArch32 ids)
             -> Maybe (Seq.Seq (MC.Stmt ARM.AArch32 ids), MC.ArchSegmentOff ARM.AArch32)
identifyCall mem stmts0 rs
  | not (null stmts0)
  , MC.RelocatableValue {} <- rs ^. MC.boundValue AR.arm_LR
  , Just retVal <- MSS.simplifyValue (rs ^. MC.boundValue AR.arm_LR)
  , Just retAddrVal <- MC.valueAsMemAddr retVal
  , Just retAddr <- MM.asSegmentOff mem retAddrVal =
      Just (stmts0, retAddr)
  | otherwise = Nothing

-- | Intended to identify a return statement.
--
-- The current implementation is to attempt to recognize the Macaw
-- 'ReturnAddr' value (placed in the LR register by
-- 'mkInitialAbsState') when it is placed in the PC (instruction
-- pointer), but unfortunately this does not work because ARM
-- semantics will clear the low bit (T32 mode) or the low two bits
-- (A32 mode) when writing to the PC to discard the mode bit in target
-- addresses.
identifyReturn :: Seq.Seq (MC.Stmt ARM.AArch32 ids)
               -> MC.RegState (MC.ArchReg ARM.AArch32) (MC.Value ARM.AArch32 ids)
               -> MA.AbsProcessorState (MC.ArchReg ARM.AArch32) ids
               -> Maybe (Seq.Seq (MC.Stmt ARM.AArch32 ids))
identifyReturn stmts s finalRegSt8 =
  if isReturnValue finalRegSt8 (s^.MC.boundValue MC.ip_reg)
  then Just stmts
  else Nothing

-- | Determines if the supplied value is the symbolic return address
-- from Macaw, modulo any ARM semantics operations (lots of ite caused
-- by the conditional execution bits for most instructions, clearing
-- of the low bits (1 in T32 mode, 2 in A32 mode).
isReturnValue :: MA.AbsProcessorState (MC.ArchReg ARM.AArch32) ids
              -> MC.Value ARM.AArch32 ids (MT.BVType (MC.RegAddrWidth (MC.ArchReg ARM.AArch32)))
              -> Bool
isReturnValue absProcState val =
  case MA.transferValue absProcState val of
    MA.ReturnAddr -> True
    _ -> False

-- | If one of the values is the abstract return address, return the other (if it is a constant)
--
-- If neither is the abstract return address (or the other value is not a constant), return 'Nothing'
asReturnAddrAndConstant
  :: MC.Memory 32
  -> MA.AbsProcessorState (MC.ArchReg ARM.AArch32) ids
  -> MC.Value ARM.AArch32 ids (MT.BVType (MC.ArchAddrWidth ARM.AArch32))
  -> MC.Value ARM.AArch32 ids (MT.BVType (MC.ArchAddrWidth ARM.AArch32))
  -> MAI.Classifier (MC.ArchSegmentOff ARM.AArch32)
asReturnAddrAndConstant mem absProcState mRet mConstant = do
  MA.ReturnAddr <- return (MA.transferValue absProcState mRet)
  Just memAddr <- return (MC.valueAsMemAddr mConstant)
  Just segOff <- return (MC.asSegmentOff mem memAddr)
  when (not (isExecutableSegOff segOff)) $ do
    fail ("Conditional return successor is not executable: " ++ show memAddr)
  return segOff

-- | Simplify nested muxes if possible
--
-- If the term is a mux and cannot be simplified, return it unchanged.  If the
-- term is not a mux, return Nothing.
--
-- We need this because the terms generated by the conditional return
-- instructions seem to always include nested muxes, which we don't want to have
-- to match against in a brittle way.  The 'MSS.simplifyArchApp' function (for
-- AArch32) has that simplification. Note that some of the other simplification
-- entry points do *not* call that function, so it is important that we use this
-- entry point. We don't need the arithmetic simplifications provided by the
-- more general infrastructure.
simplifiedMux
  :: MSS.SimplifierExtension arch
  => MC.Value arch ids tp
  -> Maybe (MC.App (MC.Value arch ids) tp)
simplifiedMux ipVal
  | Just app@(MC.Mux {}) <- MC.valueAsApp ipVal =
      MSS.simplifyArchApp app <|> pure app
  | otherwise = Nothing

data ReturnsOnBranch = ReturnsOnTrue | ReturnsOnFalse
  deriving (Eq)

-- | Inspect the IP register to determine if this statement causes a conditional return
--
-- We expect a mux where one of the IP values is the abstract return address and
-- the other is an executable address.  Ideally we would be able to say that is
-- the "next" instruction address, but we do not have a good way to determine
-- the *current* instruction address. This just means that we have a more
-- flexible recognizer for conditional returns, even though there are
-- (probably?) no ARM instructions that could return that way.
--
-- The returned values are:
--
--  * The condition of the conditional return
--  * The next IP
--  * An indicator of which branch is the return branch
--  * The statements to use as the statement list
--
-- Note that we currently don't modify the statement list, but could
identifyConditionalReturn
  :: MC.Memory 32
  -> Seq.Seq (MC.Stmt ARM.AArch32 ids)
  -> MC.RegState (MC.ArchReg ARM.AArch32) (MC.Value ARM.AArch32 ids)
  -> MA.AbsProcessorState (MC.ArchReg ARM.AArch32) ids
  -> MAI.Classifier ( MC.Value ARM.AArch32 ids MT.BoolType
                    , MC.ArchSegmentOff ARM.AArch32
                    , ReturnsOnBranch
                    , Seq.Seq (MC.Stmt ARM.AArch32 ids)
                    )
identifyConditionalReturn mem stmts s finalRegState
  | not (null stmts)
  , Just (MC.Mux _ c t f) <- simplifiedMux (s ^. MC.boundValue MC.ip_reg) =
      case asReturnAddrAndConstant mem finalRegState t f of
        MAI.ClassifySucceeded _ nextIP -> return (c, nextIP, ReturnsOnTrue, stmts)
        MAI.ClassifyFailed _ -> do
          nextIP <- asReturnAddrAndConstant mem finalRegState f t
          return (c, nextIP, ReturnsOnFalse, stmts)
  | otherwise = fail "IP is not a mux"

-- | Recognize ARM conditional returns and generate an appropriate arch-specific
-- terminator
--
-- Conditional returns are not supported in core macaw, so we need to use an
-- arch-specific terminator.  Unlike simple arch-terminators, this one requires
-- analysis that can only happen in the context of a block classifier.
--
-- Note that there are two cases below that could be handled. It seems unlikely
-- that these would be produced in practice, so they are unhandled for now.
conditionalReturnClassifier :: MAI.BlockClassifier ARM.AArch32 ids
conditionalReturnClassifier = do
  stmts <- CMR.asks MAI.classifierStmts
  mem <- CMR.asks (MAI.pctxMemory . MAI.classifierParseContext)
  regs <- CMR.asks MAI.classifierFinalRegState
  absState <- CMR.asks MAI.classifierAbsState
  (cond, nextIP, returnBranch, stmts') <- MAI.liftClassifier (identifyConditionalReturn mem stmts regs absState)
  let term = if returnBranch == ReturnsOnTrue then Arch.ReturnIf cond else Arch.ReturnIfNot cond
  writtenAddrs <- CMR.asks MAI.classifierWrittenAddrs

  jmpBounds <- CMR.asks MAI.classifierJumpBounds
  ainfo <- CMR.asks (MAI.pctxArchInfo . MAI.classifierParseContext)

  case Jmp.postBranchBounds jmpBounds regs cond of
    Jmp.BothFeasibleBranch trueJumpState falseJumpState -> do
      -- Both branches are feasible, but we don't need the "true" case because
      -- it is actually a return
      let abs' = MDC.branchBlockState ainfo absState stmts regs cond (returnBranch == ReturnsOnFalse)
      let fallthroughTarget = ( nextIP
                              , abs'
                              , if returnBranch == ReturnsOnTrue then falseJumpState else trueJumpState
                              )
      return Parsed.ParsedContents { Parsed.parsedNonterm = F.toList stmts'
                                   , Parsed.parsedTerm = Parsed.ParsedArchTermStmt term regs (Just nextIP)
                                   , Parsed.intraJumpTargets = [fallthroughTarget]
                                   , Parsed.newFunctionAddrs = []
                                   , Parsed.writtenCodeAddrs = writtenAddrs
                                   }
    Jmp.TrueFeasibleBranch _ -> fail "Infeasible false branch"
    Jmp.FalseFeasibleBranch _ -> fail "Infeasible true branch"
    Jmp.InfeasibleBranch -> fail "Branch targets are both infeasible"
