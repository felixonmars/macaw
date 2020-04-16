{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Data.Macaw.RISCV (
  -- * Macaw configurations
  riscv_info,
  -- * Type-level tags
  G.RV(..),
  G.RVRepr(..),
  -- * RISC-V Types
  RISCVReg(..),
  RISCVTermStmt,
  RISCVStmt,
  RISCVPrimFn
  ) where

import qualified Data.Macaw.CFG as MC
import qualified Data.Macaw.CFG.DemandSet as MD
import qualified Data.Macaw.Architecture.Info as MI
import qualified GRIFT.Types as G

import Data.Macaw.RISCV.Arch
import Data.Macaw.RISCV.Disassemble (riscvDisassembleFn)
import Data.Macaw.RISCV.Eval
import Data.Macaw.RISCV.Identify
import Data.Macaw.RISCV.RISCVReg

riscvDemandContext :: MD.DemandContext (rv :: G.RV)
riscvDemandContext = MD.DemandContext
  { MD.demandConstraints = \a -> a
  , MD.archFnHasSideEffects = riscvPrimFnHasSideEffects
  }

riscv_info :: RISCV rv => G.RVRepr rv -> MI.ArchitectureInfo rv
riscv_info rvRepr = G.withRV rvRepr $ MI.ArchitectureInfo
  { MI.withArchConstraints = \x -> x
  , MI.archAddrWidth = riscvAddrWidth rvRepr
  , MI.archEndianness = MC.LittleEndian
  , MI.extractBlockPrecond = \_ _ -> Right ()
  , MI.initialBlockRegs = \startIP _ -> riscvInitialBlockRegs rvRepr startIP
  , MI.disassembleFn = riscvDisassembleFn rvRepr
  , MI.mkInitialAbsState = riscvInitialAbsState rvRepr
  , MI.absEvalArchFn = \_ _ -> error $ "absEvalArchFn unimplemented in riscv_info"
  , MI.absEvalArchStmt = \_ _ -> error $ "absEvalArchStmt unimplemented in riscv_info"
  , MI.identifyCall = riscvIdentifyCall rvRepr
  , MI.archCallParams = riscvCallParams
  , MI.checkForReturnAddr = riscvCheckForReturnAddr rvRepr
  , MI.identifyReturn = riscvIdentifyReturn rvRepr
  , MI.rewriteArchFn = \_ -> error $ "rewriteArchFn unimplemented in riscv_info"
  , MI.rewriteArchStmt = \_ -> error $ "rewriteArchStmt unimplemented in riscv_info"
  , MI.rewriteArchTermStmt = \_ -> error $ "rewriteArchTermStmt unimplemented in riscv_info"
  , MI.archDemandContext = riscvDemandContext
  , MI.postArchTermStmtAbsState = \_ _ _ _ _ -> error $ "postArchTermStmtAbsState unimplemented in riscv_info"
  }
