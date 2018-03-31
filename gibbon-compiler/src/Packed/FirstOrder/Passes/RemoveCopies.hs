{-# LANGUAGE OverloadedStrings #-}
module Packed.FirstOrder.Passes.RemoveCopies where

import Data.Loc
import qualified Data.Map as M

import Packed.FirstOrder.GenericOps
import Packed.FirstOrder.Common hiding (FunDef(..))
import Packed.FirstOrder.L1.Syntax hiding (Prog(..), FunDef(..))
import Packed.FirstOrder.L2.Syntax as L2

import Debug.Trace

--------------------------------------------------------------------------------

-- Maps a location to a region
type LocEnv = M.Map LocVar Var

removeCopies :: L2.Prog -> SyM L2.Prog
removeCopies Prog{ddefs,fundefs,mainExp} = do
  fds' <- mapM (removeCopiesFn ddefs fundefs) $ M.elems fundefs
  let fundefs' = M.fromList $ map (\f -> (funname f,f)) fds'
      env2 = Env2 M.empty (initFunEnv fundefs)
      ddefs' = M.map (\ddf@DDef{dataCons} ->
                        ddf {dataCons = dataCons ++ [(indirectionTag, [(False, CursorTy)])]} )
               ddefs
  mainExp' <- case mainExp of
                Nothing -> return Nothing
                Just (mn, ty) -> Just . (,ty) <$>
                  removeCopiesExp ddefs fundefs M.empty env2 mn
  return $ Prog ddefs' fundefs' mainExp'

removeCopiesFn :: DDefs Ty2 -> NewFuns -> L2.FunDef -> SyM L2.FunDef
removeCopiesFn ddefs fundefs f@FunDef{funarg,funty,funbod} = do
  let initLocEnv = M.fromList $ map (\(LRM lc r _) -> (lc, regionVar r)) (locVars funty)
      initTyEnv  = M.singleton funarg (arrIn funty)
      env2 = Env2 initTyEnv (initFunEnv fundefs)
  bod' <- removeCopiesExp ddefs fundefs initLocEnv env2 funbod
  return $ f {funbod = bod'}

removeCopiesExp :: DDefs Ty2 -> NewFuns -> LocEnv -> Env2 Ty2 -> L L2.Exp2 -> SyM (L L2.Exp2)
removeCopiesExp ddefs fundefs lenv env2 (L p ex) = L p <$>
  case ex of
    AppE f [lin,lout] _ | isCopyFunName f -> do
      let ty@(PackedTy tycon _) = gTypeExp ddefs env2 ex
      indirection <- gensym "indirection"
      return $ unLoc $ mkLets ([(indirection,[],PackedTy tycon lout,l$ Ext $ IndirectionE tycon (lout , lenv # lout) (lin, lenv # lin))]) (l$ VarE indirection)

    LetE (v,locs,ty@(PackedTy tycon _), (L _ (AppE f [lin,lout] _))) bod | isCopyFunName f -> do
      -- trace (sdoc (v,ty)) (return ())
      LetE (v,locs,ty, l$ Ext $ IndirectionE tycon (lout , lenv # lout) (lin, lenv # lin)) <$>
        removeCopiesExp ddefs fundefs lenv (extendVEnv v ty env2) bod

    LetE (v,locs,ty, rhs) bod ->
      -- trace (sdoc (v,rhs))
      (LetE <$> (v,locs,ty,) <$> go rhs <*>
        removeCopiesExp ddefs fundefs lenv (extendVEnv v ty env2) bod)

    Ext ext ->
      case ext of
        -- Update lenv with a binding for loc
        LetLocE loc rhs bod -> do
          let reg = case rhs of
                      StartOfLE r  -> regionVar r
                      InRegionLE r -> regionVar r
                      AfterConstantLE _ lc -> lenv # lc
                      AfterVariableLE _ lc -> lenv # lc
                      FromEndLE lc         -> lenv # lc -- TODO: This needs to be fixed
          Ext <$> LetLocE loc rhs <$>
            removeCopiesExp ddefs fundefs (M.insert loc reg lenv) env2 bod
       -- Straightforward recursion
        RetE{} -> return ex
        LetRegionE r bod -> Ext <$> LetRegionE r <$> go bod
        FromEndE{}    -> return ex
        BoundsCheck{} -> return ex
        IndirectionE{} -> return ex
    -- Straightforward recursion
    VarE{}     -> return ex
    LitE{}     -> return ex
    LitSymE{}  -> return ex
    AppE{}     -> return ex
    PrimAppE{} -> return ex
    DataConE{} -> return ex
    ProjE i e  -> ProjE i <$> go e
    IfE a b c  -> IfE <$> go a <*> go b <*> go c
    MkProdE ls -> MkProdE <$> mapM go ls
    CaseE scrt mp -> do
      let L _ (VarE v) = scrt
          PackedTy _ tyloc = lookupVEnv v env2
          reg = lenv M.! tyloc
      CaseE scrt <$> mapM (docase reg lenv env2) mp
    TimeIt e ty b -> do
      e' <- go e
      return $ TimeIt e' ty b
    MapE{}  -> error $ "go: TODO MapE"
    FoldE{} -> error $ "go: TODO FoldE"
  where
    go = removeCopiesExp ddefs fundefs lenv env2
    docase reg lenv1 env21 (dcon,vlocs,bod) = do
      -- Update the envs with bindings for pattern matched variables and locations.
      -- The locations point to the same region as the scrutinee.
      let (vars,locs) = unzip vlocs
          lenv1' = foldr (\lc acc -> M.insert lc reg acc) lenv1 locs
          tys = lookupDataCon ddefs dcon
          tys' = substLocs locs tys []
          env2' = extendsVEnv (M.fromList $ zip vars tys') env21
      (dcon,vlocs,) <$> (removeCopiesExp ddefs fundefs lenv1' env2' bod)

    substLocs :: [LocVar] -> [L2.Ty2] -> [L2.Ty2] -> [L2.Ty2]
    substLocs locs tys acc =
      case (locs,tys) of
        ([],[]) -> acc
        (lc':rlocs, ty:rtys) ->
          case ty of
            PackedTy tycon _ -> substLocs rlocs rtys (acc ++ [PackedTy tycon lc'])
            ProdTy tys' -> error $ "substLocs: Unexpected type: " ++ sdoc tys'
            _ -> substLocs rlocs rtys (acc ++ [ty])
        _ -> error $ "substLocs: " ++ sdoc (locs,tys)
