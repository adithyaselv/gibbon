{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE QuasiQuotes        #-}
{-# LANGUAGE TemplateHaskell    #-}

-- | The final pass of the compiler: generate C code.

module Gibbon.Passes.Codegen
  ( codegenProg, harvestStructTys, makeName, rewriteReturns ) where

import           Control.Monad
import           Data.Bifunctor (first)
import           Data.Int
import           Data.Loc
import qualified Data.Map as M
import           Data.Maybe
import           Data.List as L
import qualified Data.Set as S
import           Language.C.Quote.C (cdecl, cedecl, cexp, cfun, cparam, csdecl, cstm, cty)
import qualified Language.C.Quote.C as C
import qualified Language.C.Syntax as C
import           Prelude hiding (init)
import           System.Directory
import           System.Environment
import           Text.PrettyPrint.Mainland
import           Text.PrettyPrint.Mainland.Class

import           Gibbon.Common
import qualified Gibbon.Language as GL
import           Gibbon.DynFlags
import           Gibbon.L2.Syntax ( Multiplicity(..) )
import           Gibbon.L4.Syntax

--------------------------------------------------------------------------------


-- | Harvest all struct tys.  All product types used anywhere in the program.
harvestStructTys :: Prog -> S.Set [Ty]
harvestStructTys (Prog _ funs mtal) =
    -- if S.null (S.difference tys0 tys1)
    S.delete [] (S.union tys0 tys1)
  where
  tys0 :: S.Set [Ty]
  tys0 = findAllProds $ concatMap allTypes allTails

  tys1 :: S.Set [Ty]
  -- All types mentioned in function arguments and returns:
  tys1 = S.fromList [ tys | fn <- funs, ProdTy tys <- funTys fn ]
  -- structs f = makeStructs $ S.toList $ harvestStructTys prg

  funTys :: FunDecl -> [Ty]
  funTys (FunDecl _ args ty _ _) = ty : (map snd args)

  allTails = (case mtal of
                Just (PrintExp t) -> [t]
                Nothing -> []) ++
             map funBody funs

  -- We may have nested products; this finds everything:
  findAllProds :: [Ty] -> S.Set [Ty]
  findAllProds = go
    where
      go []     = S.empty
      go (t:ts) =
       case t of
         ProdTy ls -> S.insert ls $ S.union (go ls) (go ts)
         _ -> go ts -- S.empty

  -- This finds all types that maybe grouped together as a ProdTy:
  allTypes :: Tail -> [Ty]
  allTypes = go
   where
    go tl =
     case tl of
       (RetValsT _)  -> []
       (AssnValsT ls bod_maybe) ->
         case bod_maybe of
           Just bod -> ProdTy (map (\(_,x,_) -> x) ls) : go bod
           Nothing  -> [ProdTy (map (\(_,x,_) -> x) ls)]
       -- This creates a demand for a struct return, but it is covered
       -- by the fun signatures already:
       (LetCallT _ binds _ _  bod) -> ProdTy (map snd binds) : go bod
       -- INVARIANT: This does not create a struct:
       -- But just in case it does in the future, we add it:
       (LetPrimCallT binds _ _ bod)-> ProdTy (map snd binds) : go bod
       (LetTrivT (_,ty,_) bod)     -> ty : go bod
       -- This should not create a struct.  Again, we add it just for the heck of it:
       (LetIfT binds (_,a,b) bod)  -> ProdTy (map snd binds) : go a ++ go b ++ go bod
       (LetTimedT _ binds rhs bod) -> ProdTy (map snd binds) : go rhs ++ go bod
       (LetArenaT _ bod)          -> ProdTy [ArenaTy] : go bod

       -- These are precisely for operating on structs:
       (LetUnpackT binds _ bod)    -> ProdTy (map snd binds) : go bod
       (LetAllocT _ vals bod)      -> ProdTy (map fst vals) : go bod

       (IfT _ a b) -> go a ++ go b
       ErrT{} -> []
       (Switch _ _ (IntAlts ls) b) -> concatMap (go . snd) ls ++ concatMap go (maybeToList b)
       (Switch _ _ (TagAlts ls) b) -> concatMap (go . snd) ls ++ concatMap go (maybeToList b)
       (TailCall _ _)    -> []
       (Goto _) -> []

--------------------------------------------------------------------------------
-- * C codegen

-- | Compile a program to C code which has the side effect of the
-- "main" expression in that program.
--
--  The boolean flag is true when we are compiling in "Packed" mode.
codegenProg :: Config -> Prog -> IO String
codegenProg cfg prg@(Prog sym_tbl funs mtal) = do
      env <- getEnvironment
      dbgTrace 1 (show (uniqueDicts $ S.toList $ harvestStructTys prg)) $ return ()
      let rtsPath = case lookup "GIBBONDIR" env of
                      Just p -> p ++"/gibbon-compiler/cbits/rts.c"
                      Nothing -> "cbits/rts.c" -- Assume we're running from the compiler dir!
      e <- doesFileExist rtsPath
      unless e $ error$ "codegen: rts.c file not found at path: "++rtsPath
                       ++"\n Consider setting GIBBONDIR to repo root.\n"
      rts <- readFile rtsPath -- TODO (maybe): We can read this in in compile time using TH
      return (rts ++ '\n' : pretty 80 (stack (map ppr defs)))
    where
      defs = fst $ runPassM cfg 0 $ do
        (prots,funs') <- unzip <$> mapM codegenFun funs
        main_expr' <- main_expr
        return ((L.nub $ makeStructs (uniqueDicts $ S.toList $ harvestStructTys prg)) ++ prots ++ funs' ++ [main_expr'])

      main_expr :: PassM C.Definition
      main_expr = do
        e <- case mtal of
               -- [2019.06.13]: CSK, Why is codegenTail always called with IntTy?
               Just (PrintExp t) -> codegenTail t (codegenTy IntTy)
               _ -> pure []
        let bod = mkSymTable ++ e
        pure $ C.FuncDef [cfun| void __main_expr() { $items:bod } |] noLoc

      codegenFun' :: FunDecl -> PassM C.Func
      codegenFun' (FunDecl nam args ty tal _) =
          do let retTy   = codegenTy ty
                 params  = map (\(v,t) -> [cparam| $ty:(codegenTy t) $id:v |]) args
             body <- codegenTail tal retTy
             let fun     = [cfun| $ty:retTy $id:nam ($params:params) {
                            $items:body
                     } |]
             return fun

      makeProt :: C.Func -> Bool -> PassM C.InitGroup
      makeProt fn ispure = do
        dflags <- getDynFlags
        let prot@(C.InitGroup decl_spec _ inits lc) = C.funcProto fn
            purattr = C.Attr (C.Id "pure" noLoc) [] noLoc
            pureAnnotOk = not (gopt Opt_No_PureAnnot dflags)
        if ispure && pureAnnotOk
        then return $ C.InitGroup decl_spec [purattr] inits lc
        else return prot

      codegenFun :: FunDecl -> PassM (C.Definition, C.Definition)
      codegenFun fd =
          do fun <- codegenFun' fd
             prot <- makeProt fun (isPure fd)
             return (C.DecDef prot noLoc, C.FuncDef fun noLoc)

      mkSymTable :: [C.BlockItem]
      mkSymTable =
        map
          (\(k,v) -> C.BlockStm [cstm| add_symbol($k, $v); |])
          (M.toList sym_tbl)

      -- C.BlockStm [cstm| for (long long $id:iters = 0; $id:iters < global_iters_param; $id:iters ++) { $items:body } |]

makeStructs :: [[Ty]] -> [C.Definition]
makeStructs [] = []
makeStructs (ts : ts') = d : makeStructs ts'
    where strName = makeName ts
          d = [cedecl| typedef struct $id:(strName ++ "_struct") { $sdecls:decls } $id:strName; |]
          decls = zipWith (\t n -> [csdecl| $ty:(codegenTy t) $id:("field"++(show n)); |])
                  ts [0 :: Int ..]

uniqueDicts :: [[Ty]] -> [[Ty]]
uniqueDicts [] = []
uniqueDicts (ts : ts') = (map f ts) : uniqueDicts ts'
    where f (SymDictTy _ t) = SymDictTy "_" t
          f t = t

-- | Replace returns with assignments to a given set of destinations.
rewriteReturns :: Tail -> [(Var,Ty)] -> Tail
rewriteReturns tl bnds =
 let go x = rewriteReturns x bnds in
 case tl of
   (RetValsT ls) -> AssnValsT [ (v,t,e) | (v,t) <- bnds | e <- ls ] Nothing
   (Goto _) -> tl

   -- Here we've already rewritten the tail to assign values
   -- somewhere.. and now we want to REREWRITE it?
   (AssnValsT _ _) -> error$ "rewriteReturns: Internal invariant broken:\n "++sdoc tl
   (e@LetCallT{bod})     -> e{bod = go bod }
   (e@LetPrimCallT{bod}) -> e{bod = go bod }
   (e@LetTrivT{bod})     -> e{bod = go bod }
   -- We don't recur on the "tails" under the if, because they're not
   -- tail with respect to our redex:
   (LetIfT bnd (a,b,c) bod) -> LetIfT bnd (a,b,c) (go bod)
   (LetTimedT flg bnd rhs bod) -> LetTimedT flg bnd rhs (go bod)
   (LetArenaT v bod) -> LetArenaT v (go bod)
   (LetUnpackT bs scrt body) -> LetUnpackT bs scrt (go body)
   (LetAllocT lhs vals body) -> LetAllocT lhs vals (go body)
   (IfT a b c) -> IfT a (go b) (go c)
   (ErrT s) -> (ErrT s)
   (Switch lbl tr alts def) -> Switch lbl tr (mapAlts go alts) (fmap go def)
   -- Oops, this is not REALLY a tail call.  Hoist it and go under:
   (TailCall f rnds) -> let (vs,ts) = unzip bnds
                            vs' = map (toVar . (++"hack")) (map fromVar vs) -- FIXME: Gensym
                        in LetCallT False (zip vs' ts) f rnds
                            (rewriteReturns (RetValsT (map VarTriv vs')) bnds)
 where
   mapAlts f (TagAlts ls) = TagAlts $ zip (map fst ls) (map (f . snd) ls)
   mapAlts f (IntAlts ls) = IntAlts $ zip (map fst ls) (map (f . snd) ls)


-- dummyLoc :: SrcLoc
-- dummyLoc = (SrcLoc (Loc (Pos "" 0 0 0) (Pos "" 0 0 0)))

codegenTriv :: Triv -> C.Exp
codegenTriv (VarTriv v) = C.Var (C.toIdent v noLoc) noLoc
codegenTriv (IntTriv i) = [cexp| ( $ty:(codegenTy IntTy) ) $int:i |]
codegenTriv (SymTriv i) = [cexp| ( $ty:(codegenTy SymTy) )$i |]
codegenTriv (TagTriv i) = [cexp| ( $ty:(codegenTy TagTyPacked) )$i |]


-- | The central codegen function.
codegenTail :: Tail -> C.Type -> PassM [C.BlockItem]

-- Void type:
codegenTail (RetValsT []) _ty   = return [ C.BlockStm [cstm| return; |] ]
-- Single return:
codegenTail (RetValsT [tr]) _ty = return [ C.BlockStm [cstm| return $(codegenTriv tr); |] ]
-- Multiple return:
codegenTail (RetValsT ts) ty =
    return $ [ C.BlockStm [cstm| return $(C.CompoundLit ty args noLoc); |] ]
    where args = map (\a -> (Nothing,C.ExpInitializer (codegenTriv a) noLoc)) ts

codegenTail (AssnValsT ls bod_maybe) ty = do
    case bod_maybe of
      Just bod -> do
        bod' <- codegenTail bod ty
        return $ [ mut (codegenTy ty) vr (codegenTriv triv) | (vr,ty,triv) <- ls ] ++ bod'
      Nothing  ->
        return $ [ mut (codegenTy ty) vr (codegenTriv triv) | (vr,ty,triv) <- ls ]

codegenTail (Switch lbl tr alts def) ty =
    case def of
      Nothing  -> let (rest,lastone) = splitAlts alts in
                  genSwitch lbl tr rest (altTail lastone) ty
      Just def -> genSwitch lbl tr alts def ty

codegenTail (TailCall v ts) _ty =
    return $ [ C.BlockStm [cstm| return $( C.FnCall (cid v) (map codegenTriv ts) noLoc ); |] ]

codegenTail (IfT e0 e1 e2) ty = do
    e1' <- codegenTail e1 ty
    e2' <- codegenTail e2 ty
    return $ [ C.BlockStm [cstm| if ($(codegenTriv e0)) { $items:e1' } else { $items:e2' } |] ]

codegenTail (ErrT s) _ty = return $ [ C.BlockStm [cstm| printf("%s\n", $s); |]
                                    , C.BlockStm [cstm| exit(1); |] ]


-- We could eliminate these earlier
codegenTail (LetTrivT (vr,rty,rhs) body) ty =
    do tal <- codegenTail body ty
       return $ [ C.BlockDecl [cdecl| $ty:(codegenTy rty) $id:vr = ($ty:(codegenTy rty)) $(codegenTriv rhs); |] ]
                ++ tal

-- TODO: extend rts with arena primitives, and invoke them here
codegenTail (LetArenaT vr body) ty =
    do tal <- codegenTail body ty
       return $ [ C.BlockDecl [cdecl| $ty:(codegenTy ArenaTy) $id:vr = alloc_arena();|] ]
              ++ tal

codegenTail (LetAllocT lhs vals body) ty =
    do let structTy = codegenTy (ProdTy (map fst vals))
           size = [cexp| sizeof($ty:structTy) |]
       tal <- codegenTail body ty
       return$ assn (codegenTy PtrTy) lhs [cexp| ( $ty:structTy *)ALLOC( $size ) |] :
               [ C.BlockStm [cstm| (($ty:structTy *)  $id:lhs)->$id:fld = $(codegenTriv trv); |]
               | (ix,(_ty,trv)) <- zip [0 :: Int ..] vals
               , let fld = "field"++show ix] ++ tal

codegenTail (LetUnpackT bs scrt body) ty =
    do let mkFld :: Int -> C.Id
           mkFld i = C.toIdent ("field" ++ show i) noLoc

           fldTys = map snd bs
           struct_ty = codegenTy (ProdTy fldTys)

           mk_bind i (v, t) = [cdecl|
             $ty:(codegenTy t) $id:v = ( ( $ty:struct_ty * ) $exp:(cid scrt) )->$id:(mkFld i);
           |]

           binds = zipWith mk_bind [0..] bs

       body' <- codegenTail body ty
       return (map C.BlockDecl binds ++ body')

-- Here we unzip the tuple into assignments to local variables.
codegenTail (LetIfT bnds (e0,e1,e2) body) ty =

    do let decls = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:vr0; |]
                   | (vr0,ty0) <- bnds ]
       let e1' = rewriteReturns e1 bnds
           e2' = rewriteReturns e2 bnds
       e1'' <- codegenTail e1' ty
       e2'' <- codegenTail e2' ty
       -- Int 1 is Boolean true:
       let ifbod = [ C.BlockStm [cstm| if ($(codegenTriv e0)) { $items:e1'' } else { $items:e2'' } |] ]
       tal <- codegenTail body ty
       return $ decls ++ ifbod ++ tal

codegenTail (LetTimedT flg bnds rhs body) ty =

    do let decls = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:vr0; |]
                   | (vr0,ty0) <- bnds ]
       let rhs' = rewriteReturns rhs bnds
       rhs'' <- codegenTail rhs' ty
       batchtime <- gensym "batchtime"
       selftimed <- gensym "selftimed"
       let ident = case bnds of
                     ((v,_):_) -> v
                     _ -> (toVar "")
           begn  = "begin_" ++ (fromVar ident)
           end   = "end_" ++ (fromVar ident)
           iters = "iters_"++ (fromVar ident)

           timebod = [ C.BlockDecl [cdecl| struct timespec $id:begn; |]
                     , C.BlockStm [cstm| clock_gettime(CLOCK_MONOTONIC_RAW, & $id:begn );  |]
                     , (if flg
                        -- Save and restore EXCEPT on the last iteration.  This "cancels out" the effect of intermediate allocations.
                        then let body = [ C.BlockStm [cstm| if ( $id:iters != global_iters_param-1) save_alloc_state(); |] ] ++
                                        rhs''++
                                        [ C.BlockStm [cstm| if ( $id:iters != global_iters_param-1) restore_alloc_state(); |] ]
                             in C.BlockStm [cstm| for (long long $id:iters = 0; $id:iters < global_iters_param; $id:iters ++) { $items:body } |]
                        else C.BlockStm [cstm| { $items:rhs'' } |])
                     , C.BlockDecl [cdecl| struct timespec $id:end; |]
                     , C.BlockStm [cstm| clock_gettime(CLOCK_MONOTONIC_RAW, &$(cid (toVar end))); |]
                     , C.BlockDecl [cdecl| double $id:batchtime = difftimespecs(&$(cid (toVar begn)), &$(cid (toVar end))); |]
                     , C.BlockDecl [cdecl| double $id:selftimed = $id:batchtime / global_iters_param; |]
                     ]
           withPrnt = timebod ++
                       if flg
                       then [ C.BlockStm [cstm| printf("ITERS: %lld\n", global_iters_param); |]
                            , C.BlockStm [cstm| printf("SIZE: %lld\n", global_size_param); |]
                            , C.BlockStm [cstm| printf("BATCHTIME: %e\n", $id:batchtime); |]
                            , C.BlockStm [cstm| printf("SELFTIMED: %e\n", $id:selftimed); |]
                            ]
                       else [ C.BlockStm [cstm| printf("SIZE: %lld\n", global_size_param); |]
                            , C.BlockStm [cstm| printf("SELFTIMED: %e\n", difftimespecs(&$(cid (toVar begn)), &$(cid (toVar end)))); |] ]
       tal <- codegenTail body ty
       return $ decls ++ withPrnt ++ tal


codegenTail (LetCallT async bnds ratr rnds body) ty
    | [] <- bnds = do tal <- codegenTail body ty
                      return $ [toStmt fnexp] ++ dosync ++ tal
    | [bnd] <- bnds  = do tal <- codegenTail body ty
                          let call = assn (codegenTy (snd bnd)) (fst bnd) (fnexp)
                          return $ [call] ++ dosync ++ tal
    | otherwise = do
       nam <- gensym $ toVar "tmp_struct"
       let bind (v,t) f = assn (codegenTy t) v (C.Member (cid nam) (C.toIdent f noLoc) noLoc)
           fields = map (\i -> "field" ++ show i) [0 :: Int .. length bnds - 1]
           ty0 = ProdTy $ map snd bnds
           init = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:nam = $(fnexp); |] ] ++ dosync
       tal <- codegenTail body ty
       return $ init ++ zipWith bind bnds fields ++ tal
  where
    dospawn = if async
              then text "cilk_spawn"
              else empty
    dosync = if async
             then [ C.BlockStm [cstm| $exp:(C.EscExp "cilk_sync" noLoc); |] ]
             else  []
    fncall = C.FnCall (cid ratr) (map codegenTriv rnds) noLoc
    fnexp = C.EscExp (prettyCompact (dospawn <> space <> ppr fncall)) noLoc

codegenTail (LetPrimCallT bnds prm rnds body) ty =
    do bod' <- codegenTail body ty
       dflags <- getDynFlags
       let isPacked = gopt Opt_Packed dflags
           noGC = gopt Opt_DisableGC dflags

       pre <- case prm of
                 AddP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv pleft) + $(codegenTriv pright); |] ]
                 SubP -> let (outV,outT) = head bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv pleft) - $(codegenTriv pright); |] ]
                 MulP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv pleft) * $(codegenTriv pright); |]]
                 DivP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv pleft) / $(codegenTriv pright); |]]
                 ModP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv pleft) % $(codegenTriv pright); |]]
                 ExpP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = expll($(codegenTriv pleft), $(codegenTriv pright)); |]]
                 RandP -> let [(outV,outT)] = bnds in pure
                          [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = rand(); |]]
                 EqP -> let [(outV,outT)] = bnds
                            [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv pleft) == $(codegenTriv pright)); |]]
                 LtP -> let [(outV,outT)] = bnds
                            [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv pleft) < $(codegenTriv pright)); |]]
                 GtP -> let [(outV,outT)] = bnds
                            [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv pleft) > $(codegenTriv pright)); |]]
                 LtEqP -> let [(outV,outT)] = bnds
                              [pleft,pright] = rnds in pure
                          [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv pleft) <= $(codegenTriv pright)); |]]
                 GtEqP -> let [(outV,outT)] = bnds
                              [pleft,pright] = rnds in pure
                          [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv pleft) >= $(codegenTriv pright)); |]]
                 OrP -> let [(outV,outT)] = bnds
                            [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv pleft) || $(codegenTriv pright)); |]]
                 AndP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv pleft) && $(codegenTriv pright)); |]]
                 DictInsertP _ -> let [(outV,ty)] = bnds
                                      [(VarTriv arena),(VarTriv dict),keyTriv,valTriv] = rnds in pure
                    [ C.BlockDecl [cdecl| $ty:(codegenTy ty) $id:outV = dict_insert_ptr($id:arena, $id:dict, $(codegenTriv keyTriv), $(codegenTriv valTriv)); |] ]
                 DictLookupP _ -> let [(outV,ty)] = bnds
                                      [(VarTriv dict),keyTriv] = rnds in pure
                    [ C.BlockDecl [cdecl| $ty:(codegenTy ty) $id:outV = dict_lookup_ptr($id:dict, $(codegenTriv keyTriv)); |] ]
                 DictEmptyP _ty -> let [(outV,ty)] = bnds
                                   in pure [ C.BlockDecl [cdecl| $ty:(codegenTy ty) $id:outV = 0; |] ]
                 DictHasKeyP PtrTy -> let [(outV,IntTy)] = bnds
                                          [(VarTriv dict)] = rnds in pure
                    [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:outV = dict_has_key_ptr($id:dict); |] ]

                 NewBuffer mul -> do
                   let [(reg, CursorTy),(outV,CursorTy)] = bnds
                       bufsize = codegenMultiplicity mul
                   pure
                     [ C.BlockDecl [cdecl| $ty:(codegenTy RegionTy)* $id:reg = alloc_region($id:bufsize); |]
                     , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = $id:reg->start_ptr; |]
                     ]
                 ScopedBuffer mul -> let [(outV,CursorTy)] = bnds
                                         bufsize = codegenMultiplicity mul
                                     in pure
                             [ C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = ( $ty:(codegenTy CursorTy) )ALLOC_SCOPED($id:bufsize); |] ]

                 InitSizeOfBuffer mul -> let [(sizev,IntTy)] = bnds
                                             bufsize = codegenMultiplicity mul
                                         in pure
                                            [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:sizev = $id:bufsize; |] ]

                 FreeBuffer -> if noGC
                               then pure []
                               else
                                 let [(VarTriv reg),(VarTriv _rcur),(VarTriv endr_cur)] = rnds
                                 in pure
                                 [ C.BlockStm [cstm| if ($id:reg->refcount != REG_FREED) { free_region($id:endr_cur); }  |]
                                 , C.BlockStm [cstm| free($id:reg); |]
                                 ]

                 WriteTag -> let [(outV,CursorTy)] = bnds
                                 [(TagTriv tag),(VarTriv cur)] = rnds in pure
                             [ C.BlockStm [cstm| *($id:cur) = $tag; |]
                             , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = $id:cur + 1; |] ]
                 ReadTag -> let [(tagV,TagTyPacked),(curV,CursorTy)] = bnds
                                [(VarTriv cur)] = rnds in pure
                            [ C.BlockDecl [cdecl| $ty:(codegenTy TagTyPacked) $id:tagV = *($id:cur); |]
                            , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:curV = $id:cur + 1; |] ]

                 WriteScalar s -> let [(outV,CursorTy)] = bnds
                                      [val,(VarTriv cur)] = rnds in pure
                                  [ C.BlockStm [cstm| *( $ty:(codegenTy (scalarToTy s))  *)($id:cur) = $(codegenTriv val); |]
                                  , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = ($id:cur) + sizeof( $ty:(codegenTy (scalarToTy s)) ); |] ]

                 ReadScalar s -> let [(valV,valTy),(curV,CursorTy)] = bnds
                                     [(VarTriv cur)] = rnds in pure
                                     [ C.BlockDecl [cdecl| $ty:(codegenTy valTy) $id:valV = *( $ty:(codegenTy valTy) *)($id:cur); |]
                                     , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:curV = ($id:cur) + sizeof( $ty:(codegenTy (scalarToTy s))); |] ]

                 ReadCursor -> let [(next,CursorTy),(afternext,CursorTy)] = bnds
                                   [(VarTriv cur)] = rnds in pure
                               [ C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:next = *($ty:(codegenTy CursorTy) *) ($id:cur); |]
                               , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:afternext = ($id:cur) + 8; |]
                               ]

                 WriteCursor -> let [(outV,CursorTy)] = bnds
                                    [val,(VarTriv cur)] = rnds in pure
                                 [ C.BlockStm [cstm| *( $ty:(codegenTy CursorTy)  *)($id:cur) = $(codegenTriv val); |]
                                 , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = ($id:cur) + 8; |] ]

                 BumpRefCount -> let [(VarTriv end_r1), (VarTriv end_r2)] = rnds
                                 in pure [ C.BlockStm [cstm| bump_ref_count($id:end_r1, $id:end_r2); |] ]

                 BoundsCheck -> do
                   new_chunk   <- gensym "new_chunk"
                   chunk_start <- gensym "chunk_start"
                   chunk_end   <- gensym "chunk_end"
                   let [(IntTriv i),(VarTriv bound), (VarTriv cur)] = rnds
                       bck = [ C.BlockDecl [cdecl| $ty:(codegenTy ChunkTy) $id:new_chunk = alloc_chunk($id:bound); |]
                             , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:chunk_start = $id:new_chunk.start_ptr; |]
                             , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:chunk_end = $id:new_chunk.end_ptr; |]
                             , C.BlockStm  [cstm|  $id:bound = $id:chunk_end; |]
                             , C.BlockStm  [cstm|  *($ty:(codegenTy TagTyPacked) *) ($id:cur) = ($int:(GL.redirectionAlt)); |]
                             , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) redir =  $id:cur + 1; |]
                             , C.BlockStm  [cstm|  *($ty:(codegenTy CursorTy) *) redir = $id:chunk_start; |]
                             , C.BlockStm  [cstm|  $id:cur = $id:chunk_start; |]
                             ]
                   return [ C.BlockStm [cstm| if (($id:cur + $int:i) > $id:bound) { $items:bck }  |] ]

                 SizeOfPacked -> let [(sizeV,IntTy)] = bnds
                                     [(VarTriv startV), (VarTriv endV)] = rnds
                                 in pure
                                   [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:sizeV = $id:endV - $id:startV; |] ]
                 SizeOfScalar -> let [(sizeV,IntTy)] = bnds
                                     [(VarTriv w)]   = rnds
                                 in pure
                                   [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:sizeV = sizeof($id:w); |] ]


                 GetFirstWord ->
                  let [ptr] = rnds in
                  case bnds of
                    [(outV,outTy)] -> pure
                     [ C.BlockDecl [cdecl|
                            $ty:(codegenTy outTy) $id:outV =
                              * (( $ty:(codegenTy outTy) *) $(codegenTriv ptr));
                          |] ]
                    _ -> error $ "wrong number of return bindings from GetFirstWord: "++show bnds

                 SizeParam -> let [(outV,IntTy)] = bnds in pure
                      [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:outV = global_size_param; |] ]

                 PrintInt | [] <- bnds -> let [arg] = rnds in pure
                                          [ C.BlockStm [cstm| printf("%lld", $(codegenTriv arg)); |] ]
                          | otherwise -> error$ "wrong number of return values expected from PrintInt prim: "++show bnds

                 PrintSym | [] <- bnds -> let [arg] = rnds in pure
                                          [ C.BlockStm [cstm| print_symbol($(codegenTriv arg)); |] ]
                          | otherwise -> error$ "wrong number of return values expected from PrintInt prim: "++show bnds

                 PrintString str
                     | [] <- bnds, [] <- rnds -> pure [ C.BlockStm [cstm| fputs( $string:str, stdout ); |] ]
                     | otherwise -> error$ "wrong number of args/return values expected from PrintString prim: "++show (rnds,bnds)

                 -- FINISHME: Codegen here depends on whether we are in --packed mode or not.
                 ReadPackedFile mfile tyc
                     | [] <- rnds, [(outV,_outT)] <- bnds -> do
                             let filename = case mfile of
                                              Just f  -> [cexp| $string:f |] -- Fixed at compile time.
                                              Nothing -> [cexp| read_benchfile_param() |] -- Will be set by command line arg.
                                 unpackName = GL.mkUnpackerName tyc
                                 unpackcall = LetCallT False [(outV,PtrTy),(toVar "junk",CursorTy)]
                                                    unpackName [VarTriv (toVar "ptr")] (AssnValsT [] Nothing)

                                 mmap_size = varAppend outV "_size"

                                 mmapCode =
                                  [ C.BlockDecl[cdecl| int fd = open( $filename, O_RDONLY); |]
                                  , C.BlockStm[cstm| { if(fd == -1) { fprintf(stderr,"fopen failed\n"); abort(); }} |]
                                  , C.BlockDecl[cdecl| struct stat st; |]
                                  , C.BlockStm  [cstm| fstat(fd, &st); |]
                                  , C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:mmap_size = st.st_size;|]
                                  , C.BlockDecl[cdecl| $ty:(codegenTy CursorTy) ptr = ($ty:(codegenTy CursorTy)) mmap(0,st.st_size,PROT_READ,MAP_PRIVATE,fd,0); |]
                                  , C.BlockStm[cstm| { if(ptr==MAP_FAILED) { fprintf(stderr,"mmap failed\n"); abort(); }} |]
                                  ]
                             docall <- if isPacked
                                       -- In packed mode we eagerly FORCE the IO to happen before we start benchmarking:
                                       then pure [ C.BlockStm [cstm| { int sum=0; for(int i=0; i < st.st_size; i++) sum += ptr[i]; } |]
                                                 , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = ptr; |]]
                                       else codegenTail unpackcall (codegenTy voidTy)
                             return $ mmapCode ++ docall
                     | otherwise -> error $ "ReadPackedFile, wrong arguments "++show rnds++", or expected bindings "++show bnds

                 MMapFileSize v -> do
                       let [(outV,IntTy)] = bnds
                           -- Must match with mmap_size set by ReadPackedFile
                           mmap_size = varAppend v "_size"
                       return [ C.BlockDecl[cdecl| $ty:(codegenTy IntTy) $id:outV = $id:mmap_size; |] ]

                 ParSync -> return [ C.BlockStm [cstm| $exp:(C.EscExp "cilk_sync" noLoc); |] ]

                 Gensym  -> do
                   let [(outV,SymTy)] = bnds
                   return [ C.BlockDecl [cdecl| $ty:(codegenTy SymTy) $id:outV = gensym(); |] ]

                 FreeSymTable -> return [C.BlockStm [cstm| free_symtable(); |]]

                 oth -> error$ "FIXME: codegen needs to handle primitive: "++show oth
       return $ pre ++ bod'

codegenTail (Goto lbl) _ty = do
  return [ C.BlockStm [cstm| goto $id:lbl; |] ]

-- | The sizes for all mulitplicities are defined as globals in the RTS.
-- Note: Must be consistent with the names in RTS!
codegenMultiplicity :: Multiplicity -> Var
codegenMultiplicity mul =
  case mul of
    BigInfinite -> toVar "global_init_biginf_buf_size"
    Infinite    -> toVar "global_init_inf_buf_size"
    Bounded     -> error $ "codegenMultiplicity: Bounded buffers not handled yet."


splitAlts :: Alts -> (Alts, Alts)
splitAlts (TagAlts ls) = (TagAlts (init ls), TagAlts [last ls])
splitAlts (IntAlts ls) = (IntAlts (init ls), IntAlts [last ls])

-- | Take a "singleton" Alts and extract the Tail.
altTail :: Alts -> Tail
altTail (TagAlts [(_,t)]) = t
altTail (IntAlts [(_,t)]) = t
altTail oth = error $ "altTail expected a 'singleton' Alts, got: "++ abbrv 80 oth


-- | Generate a linear chain of tag tests.  Usually less efficient
-- than letting the C compiler compile a switch statement.
_genIfCascade :: Triv -> Alts -> Tail -> C.Type -> PassM [C.BlockItem]
_genIfCascade tr alts lastE ty =
    do let trE = codegenTriv tr
           alts' = normalizeAlts alts
       altPairs <- forM alts' $ \(lhs, rhs) ->
                   do tal <- codegenTail rhs ty
                      return (C.BinOp C.Eq trE lhs noLoc, mkBlock tal)
       let mkIf [] = do tal <- codegenTail lastE ty
                        return $ Just $ mkBlock tal
           mkIf ((cond,rhs) : rest) = do rest' <- mkIf rest
                                         return $ Just $ C.If cond rhs rest' noLoc
       ifExpr <- mkIf altPairs
       return $ [ C.BlockStm (fromJust ifExpr) ]

-- Helper for lhs of a case
mk_tag_lhs :: (Integral a, Show a) => a -> C.Exp
mk_tag_lhs lhs = C.Const (C.IntConst (show lhs) C.Unsigned (fromIntegral lhs) noLoc) noLoc

mk_int_lhs :: (Integral a, Show a) => a -> C.Exp
mk_int_lhs lhs = C.Const (C.IntConst (show lhs) C.Signed   (fromIntegral lhs) noLoc) noLoc

normalizeAlts :: Alts -> [(C.Exp, Tail)]
normalizeAlts alts =
    case alts of
      TagAlts as -> map (first mk_tag_lhs) as
      IntAlts as -> map (first mk_int_lhs) as

-- | Generate a proper switch expression instead.
genSwitch :: Label -> Triv -> Alts -> Tail -> C.Type -> PassM [C.BlockItem]
genSwitch lbl tr alts lastE ty =
    do let go :: [(C.Exp,Tail)] -> PassM [C.Stm]
           go [] = do tal <- codegenTail lastE ty
                      return [[cstm| default: $stm:(mkBlock tal) |]]
           go ((ex,tl):rst) =
               do tal <- codegenTail tl ty
                  let tal2 = tal ++ [ C.BlockStm [cstm| break; |] ]
                  let this = [cstm| case $exp:ex : $stm:(mkBlock tal2) |]
                  rst' <- go rst
                  return (this:rst')
       alts' <- go (normalizeAlts alts)
       let body = mkBlock [ C.BlockStm a | a <- alts' ]
       return $ [ C.BlockStm [cstm| $id:lbl: ; |]
                , C.BlockStm [cstm| switch ( $exp:(codegenTriv tr) ) $stm:body |]]

-- | The identifier after typename refers to typedefs defined in rts.c
--
codegenTy :: Ty -> C.Type
codegenTy IntTy = [cty|typename IntTy|]
codegenTy BoolTy = [cty|typename BoolTy|]
codegenTy TagTyPacked = [cty|typename TagTyPacked|]
codegenTy TagTyBoxed  = [cty|typename TagTyBoxed|]
codegenTy SymTy = [cty|typename SymTy|]
codegenTy PtrTy = [cty|typename PtrTy|] -- char* - Hack, this could be void* if we have enough casts. [2016.11.06]
codegenTy CursorTy = [cty|typename CursorTy|]
codegenTy RegionTy = [cty|typename RegionTy|]
codegenTy ChunkTy = [cty|typename ChunkTy|]
codegenTy (ProdTy []) = [cty|void*|]
codegenTy (ProdTy ts) = C.Type (C.DeclSpec [] [] (C.Tnamed (C.Id nam noLoc) [] noLoc) noLoc) (C.DeclRoot noLoc) noLoc
    where nam = makeName ts
codegenTy (SymDictTy _ _t) = C.Type (C.DeclSpec [] [] (C.Tnamed (C.Id "dict_item_t*" noLoc) [] noLoc) noLoc) (C.DeclRoot noLoc) noLoc
codegenTy ArenaTy = [cty|typename ArenaTy|]

makeName :: [Ty] -> String
makeName tys = concatMap makeName' tys ++ "Prod"

makeName' :: Ty -> String
makeName' IntTy       = "Int64"
makeName' SymTy       = "Sym"
makeName' BoolTy      = "Bool"
makeName' CursorTy    = "Cursor"
makeName' TagTyPacked = "Tag"
makeName' TagTyBoxed  = makeName' IntTy
makeName' PtrTy = "Ptr"
makeName' (SymDictTy _ _ty) = "Dict"
makeName' RegionTy = "Region"
makeName' ChunkTy  = "Chunk"
makeName' ArenaTy  = "Arena"
makeName' (ProdTy tys) = "ProdTy: " ++ concatMap makeName' tys

mkBlock :: [C.BlockItem] -> C.Stm
mkBlock ss = C.Block ss noLoc

cid :: Var -> C.Exp
cid v = C.Var (C.toIdent v noLoc) noLoc

toStmt :: C.Exp -> C.BlockItem
toStmt x = C.BlockStm [cstm| $exp:x; |]

-- | Create a NEW lexical binding.
assn :: (C.ToIdent v, C.ToExp e) => C.Type -> v -> e -> C.BlockItem
assn t x y = C.BlockDecl [cdecl| $ty:t $id:x = $exp:y; |]

-- | Mutate an existing binding:
mut :: (C.ToIdent v, C.ToExp e) => C.Type -> v -> e -> C.BlockItem
mut _t x y = C.BlockStm [cstm| $id:x = $exp:y; |]
