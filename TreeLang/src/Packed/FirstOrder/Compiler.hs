{-# LANGUAGE PartialTypeSignatures #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# LANGUAGE NamedFieldPuns        #-}
-- | The compiler pipeline, assembled from several passes.

module Packed.FirstOrder.Compiler
    ( -- * Compiler entrypoints
      compile, compileCmd
     -- * Configuration options and parsing
     , Config (..), Mode(..), Input(..)
     , configParser, configWithArgs, defaultConfig
    )
  where

import Control.DeepSeq
import Control.Exception
import Control.Monad.State.Strict
import Options.Applicative
import Packed.FirstOrder.Common
import qualified Packed.FirstOrder.HaskellFrontend as HS
import Packed.FirstOrder.Interpreter (Val (..), execProg)
import qualified Packed.FirstOrder.L1_Source as L1
import Packed.FirstOrder.LTraverse (inferEffects)
import qualified Packed.FirstOrder.LTraverse as L2
import Packed.FirstOrder.Passes.Cursorize
import Packed.FirstOrder.Passes.Flatten
import Packed.FirstOrder.Passes.Lower
import qualified Packed.FirstOrder.SExpFrontend as SExp
import Packed.FirstOrder.Target (codegenProg)
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
import System.IO.Error (isDoesNotExistError)
import System.Process
import Text.PrettyPrint.GenericPretty

------------------------------------------------------------

import Data.Set as S hiding (map)

----------------------------------------
-- PASS STUBS
----------------------------------------
-- All of these need to be implemented, but are just the identity
-- function for now.

-- | Rename all local variables
freshNames :: L1.Prog -> SyM L1.Prog
freshNames (L1.Prog defs funs main) =
    do main' <- case main of
                  Nothing -> return Nothing
                  Just m -> do m' <- freshExp [] m
                               return $ Just m'
       funs' <- freshFuns funs
       return $ L1.Prog defs funs' main'
    where freshFuns = mapM freshFun
          freshFun (FunDef nam (narg,targ) ty bod) =
              do narg' <- gensym narg
                 bod' <- freshExp [(narg,narg')] bod
                 return $ FunDef nam (narg',targ) ty bod'

          freshExp :: [(Var,Var)] -> L1.Exp -> SyM L1.Exp
          freshExp vs (L1.VarE v) =
              case lookup v vs of
                Nothing -> return $ L1.VarE v
                Just v' -> return $ L1.VarE v'
          freshExp _ (L1.LitE i) =
              return $ L1.LitE i
          freshExp vs (L1.AppE v e) =
              do e' <- freshExp vs e
                 return $ L1.AppE v e'
          freshExp vs (L1.PrimAppE p es) =
              do es' <- mapM (freshExp vs) es
                 return $ L1.PrimAppE p es'
          freshExp vs (L1.LetE (v,t,e1) e2) =
              do e1' <- freshExp vs e1
                 v' <- gensym v
                 e2' <- freshExp ((v,v'):vs) e2
                 return $ L1.LetE (v',t,e1') e2'
          freshExp vs (L1.IfE e1 e2 e3) =
              do e1' <- freshExp vs e1
                 e2' <- freshExp vs e2
                 e3' <- freshExp vs e3
                 return $ L1.IfE e1' e2' e3'
          freshExp vs (L1.ProjE i e) =
              do e' <- freshExp vs e
                 return $ L1.ProjE i e'
          freshExp vs (L1.MkProdE es) =
              do es' <- mapM (freshExp vs) es
                 return $ L1.MkProdE es'
          freshExp vs (L1.CaseE e mp) =
              do e' <- freshExp vs e
                 mp' <- mapM (\(c,args,ae) -> do
                                args' <- mapM gensym args
                                let vs' = (zip args args') ++ vs
                                ae' <- freshExp vs' ae
                                return (c,args',ae')) mp
                 return $ L1.CaseE e' mp'
          freshExp vs (L1.MkPackedE c es) =
              do es' <- mapM (freshExp vs) es
                 return $ L1.MkPackedE c es'
          freshExp vs (L1.TimeIt e t) =
              do e' <- freshExp vs e
                 return $ L1.TimeIt e' t
          freshExp vs (L1.MapE (v,t,b) e) =
              do b' <- freshExp vs b
                 e' <- freshExp vs e
                 return $ L1.MapE (v,t,b') e'
          freshExp vs (L1.FoldE (v1,t1,e1) (v2,t2,e2) e3) =
              do e1' <- freshExp vs e1
                 e2' <- freshExp vs e2
                 e3' <- freshExp vs e3
                 return $ L1.FoldE (v1,t1,e1') (v2,t2,e2') e3'

-- | Inline trivial let bindings (binding a var to a var or int), mainly to clean up
--   the output of `flatten`.
inlineTriv :: L1.Prog -> L1.Prog
inlineTriv (L1.Prog defs funs main) =
    L1.Prog defs (fmap inlineTrivFun funs) (fmap inlineTrivExp main)
  where
    inlineTrivFun (FunDef nam (narg,targ) ty bod) =
      FunDef nam (narg,targ) ty (inlineTrivExp bod)

inlineTrivExp :: L1.Exp -> L1.Exp
inlineTrivExp = go []
  where
   go :: [(Var,L1.Exp)] -> L1.Exp -> L1.Exp
   go env (L1.VarE v) =
       case lookup v env of
         Nothing -> L1.VarE v
         Just e  -> e
   go _env (L1.LitE i) = L1.LitE i
   go env (L1.AppE v e) = L1.AppE v $ go env e
   go env (L1.PrimAppE p es) = L1.PrimAppE p $ map (go env) es
   go env (L1.LetE (v,t,e') e) =
       case e' of
         L1.VarE v' -> case lookup v' env of
                         Nothing  -> go ((v,e'):env) e
                         Just e'' -> go ((v,e''):env) e
         L1.LitE _i -> go ((v,e'):env) e
         _ -> L1.LetE (v,t,go env e') (go env e)
   go env (L1.IfE e1 e2 e3) =
       L1.IfE (go env e1) (go env e2) (go env e3)
   go env (L1.ProjE i e) = L1.ProjE i $ go env e
   go env (L1.MkProdE es) = L1.MkProdE $ map (go env) es
   go env (L1.CaseE e mp) =
       let e' = go env e
           mp' = map (\(c,args,ae) -> (c,args,go env ae)) mp
       in L1.CaseE e' mp'
   go env (L1.MkPackedE c es) = L1.MkPackedE c $ map (go env) es
   go env (L1.TimeIt e t) = L1.TimeIt (go env e) t
   go env (L1.MapE (v,t,e') e) = L1.MapE (v,t,go env e') (go env e)
   go env (L1.FoldE (v1,t1,e1) (v2,t2,e2) e3) =
       L1.FoldE (v1,t1,go env e1) (v2,t2,go env e2) (go env e3)



-- | Find all local variables bound by case expressions which must be
-- traversed, but which are not by the current program.
findMissingTraversals :: L2.Prog -> SyM (Set Var)
findMissingTraversals _ = pure S.empty

-- | Add calls to an implicitly-defined, polymorphic "traverse"
-- function of type `p -> ()` for any packed type p.
addTraversals :: Set Var -> L2.Prog -> SyM L2.Prog
addTraversals _ p = pure p

-- | Add calls to an implicitly-defined, polymorphic "copy" function,
--   of type `p -> p` that works on all packed data `p`.  A copy is
--   added every time constraints conflict disallowing an argument of
--   a data constructor to be unified with the needed output location.
addCopies :: L2.Prog -> SyM L2.Prog
addCopies p = pure p

-- | Generate code
lowerCopiesAndTraversals :: L2.Prog -> SyM L2.Prog
lowerCopiesAndTraversals p = pure p


-- Configuring and launching the compiler.
--------------------------------------------------------------------------------

data Config = Config
  { input     :: Input
  , mode      :: Mode -- ^ How to run, which backend.
  , packed    :: Bool -- ^ Use packed representation.
  , verbosity :: Int  -- ^ Debugging output, equivalent to DEBUG env var.
  }

-- | What input format to expect on disk.
data Input = Haskell
           | SExpr
           | Unspecified
  deriving (Show,Read,Eq,Ord,Enum,Bounded)

-- | How far to run the compiler/interpreter.
data Mode = ToParse  -- ^ Parse and then stop
          | ToC      -- ^ Compile to C
          | ToExe    -- ^ Compile to C then build a binary.
          | RunExe   -- ^ Compile to executable then run.
          | Interp2  -- ^ Interp late in the compiler pipeline.
          | Interp1  -- ^ Interp early.  Not implemented.
  deriving (Show,Read,Eq,Ord,Enum,Bounded)

defaultConfig :: Config
defaultConfig =
  Config { input = Unspecified
         , mode  = ToExe
         , packed = False
         , verbosity = 1
         }

configParser :: Parser Config
configParser = Config <$> inputParser <*> modeParser
                      <*> switch (short 'p' <> long "packed" <>
                                  help "enable packed tree representation in C backend")
                      <*> (option auto (short 'v' <> long "verbose" <>
                                       help "Set the debug output level, 1-5, mirrors DEBUG env var.")
                           <|> pure 1)
 where
  -- Most direct way, but I don't like it:
  _inputParser :: Parser Input
  _inputParser = option auto
   ( long "input"
        <> metavar "I"
        <> help ("Input file format, if unspecified based on file extension. " ++
               "Options are: "++show [minBound .. maxBound::Input]))
  _modeParser :: Parser Mode
  _modeParser = option auto
   ( long "mode"
        <> metavar "I"
        <> help ("Compilation mode. " ++
                "Options are: "++show [minBound .. maxBound::Mode]))

  inputParser :: Parser Input
                -- I'd like to display a separator and some more info.  How?
  inputParser = -- infoOption "foo" (help "bar") <*>
                flag' Haskell (long "hs")  <|>
                flag Unspecified SExpr (long "sexp")

  modeParser = -- infoOption "foo" (help "bar") <*>
               flag' ToParse (long "parse" <> help "only parse, then print & stop") <|>
               flag' ToC     (long "toC" <> help "compile to a C file, named after the input") <|>
               flag' Interp1 (long "interp1" <> help "run through the interpreter early, right after parsing") <|>
               flag' Interp2 (short 'i' <> long "interp2" <>
                              help "run through the interpreter after cursor insertion") <|>
               flag' RunExe  (short 'r' <> long "run"     <> help "compile and then run executable") <|>
               flag ToExe ToExe (long "exe"  <> help "compile through C to executable (default)")

-- | Parse configuration as well as file arguments.
configWithArgs :: Parser (Config,[FilePath])
configWithArgs = (,) <$> configParser
                     <*> some (argument str (metavar "FILES..."
                                             <> help "Files to compile."))

----------------------------------------

-- | Command line version of the compiler entrypoint.  Parses command
-- line arguments given as string inputs.
compileCmd :: [String] -> IO ()
compileCmd args = withArgs args $
    do (cfg,files) <- execParser opts
       mapM_ (compile cfg) files
  where
    opts = info (helper <*> configWithArgs)
      ( fullDesc
     <> progDesc "Compile FILES according to the below options."
     <> header "A compiler for a minature tree traversal language" )


sepline :: String
sepline = replicate 80 '='

lvl :: Int
lvl = 2

-- | Compiler entrypoint, given a full configuration and a list of
-- files to process.
compile :: Config -> FilePath -> IO ()
-- compileFile :: (FilePath -> IO (L1.Prog,Int)) -> FilePath -> IO ()
compile Config{input,mode,packed,verbosity} fp = do
  -- TERRIBLE HACK!!  This value is global, "pure" and can be read anywhere
  when (verbosity > 1) $ do
    setEnv "DEBUG" (show verbosity)
    l <- evaluate dbgLvl
    hPutStrLn stderr$ " ! We set DEBUG based on command-line verbose arg: "++show l

  let parser = case input of
                 Haskell -> HS.parseFile
                 SExpr   -> SExp.parseFile
                 Unspecified ->
                   case takeExtension fp of
                     ".hs"   -> HS.parseFile
                     ".sexp" -> SExp.parseFile
                     ".rkt"  -> SExp.parseFile
                     oth -> error$ "compile: unrecognized file extension: "++
                                   show oth++"  Please specify compile input format."
  (l1,cnt0) <- parser fp
  let printParse l = dbgPrintLn l $ sdoc l1
  if mode == ToParse
   then do -- dbgPrintLn lvl "Parsed program:"
           -- dbgPrintLn l sepline
           printParse 0
   else do
    dbgPrintLn lvl $ "Compiler pipeline starting, parsed program:\n"++sepline
    printParse lvl
    let pass :: (Out b, NFData a, NFData b) => String -> (a -> SyM b) -> a -> StateT Int IO b
        pass who fn x = do
          cnt <- get
          _ <- lift $ evaluate $ force x
          let (y,cnt') = runSyM cnt (fn x)
          put cnt'
          lift$ dbgPrintLn lvl $ "\nPass output, " ++who++":\n"++sepline
          _ <- lift $ evaluate $ force y
          lift$ dbgPrintLn lvl $ sdoc y
          return y

        -- No reason to chatter from passes that are stubbed out anyway:
        pass' :: (Out b, NFData b) => String -> (a -> SyM b) -> a -> StateT Int IO b
        pass' _ fn x = do
          cnt <- get
          let (y,cnt') = runSyM cnt (fn x)
          put cnt'
          _ <- lift $ evaluate $ force y
          return y

    when (mode == Interp1) $
      error "Early-phase interpreter not implemented yet!"

    let outfile = (replaceExtension fp ".c")
        exe     = replaceExtension fp ".exe"

    clearFile outfile
    clearFile exe

    -- Repurposing L1 passes for L2:
    let flatten2 :: L2.Prog -> SyM L2.Prog
        flatten2 = L2.mapMExprs (flattenExp (L1.ddefs l1))
        inline2 :: L2.Prog -> SyM L2.Prog
        inline2 p = return (L2.mapExprs (\_ -> inlineTrivExp) p)
    str <- evalStateT
             (do l1b <-       pass "freshNames"               freshNames               l1
                 l1c <-       pass "flatten"                  flatten                  l1b
                 l1d <-       pass "inlineTriv"               (return . inlineTriv)    l1c
                 l2  <-       pass  "inferEffects"            inferEffects             l1d
                 l2' <-
                     if packed
                     then do
                       mt  <- pass' "findMissingTraversals"    findMissingTraversals    l2
                       l2b <- pass' "addTraversals"            (addTraversals mt)       l2
                       l2c <- pass' "addCopies"                addCopies                l2b
                       l2d <- pass' "lowerCopiesAndTraversals" lowerCopiesAndTraversals l2c
--                     l2e <- pass  "cursorize"                cursorize                l2d
                       l2e <- pass  "cursorDirect"             cursorDirect             l2d
                       -- l2f <- pass "flatten"                   flatten2                 l2e
                       -- l2g <- pass "inlineTriv"                inline2                  l2f
                       return l2e
                     else return l2
                 l3  <-       pass  "lower"                    (lower packed)           l2'

                 if mode == Interp2
                  then do mapM_ (\(IntVal v) -> liftIO $ print v) (execProg l3)
                          liftIO $ exitSuccess
                  else do
                   str <- lift (codegenProg l3)
                   -- The C code is long, so put this at a higher level.
                   lift$ dbgPrintLn lvl $ "\nFinal C codegen: "++show (length str)++" characters."
                   lift$ dbgPrintLn 4 sepline
                   lift$ dbgPrintLn 4 str
                   return str)
              cnt0

    writeFile outfile str
    when (mode == ToExe || mode == RunExe) $ do
      cd <- system $ "gcc -std=gnu11 -O3 "++outfile++" -o "++ exe
      case cd of
       ExitFailure n -> error$ "C compiler failed!  Code: "++show n
       ExitSuccess -> do
         when (mode == RunExe)$ do
          exepath <- makeAbsolute exe
          c2 <- system exepath
          case c2 of
            ExitSuccess -> return ()
            ExitFailure n -> error$ "Treelang program exited with error code "++ show n


clearFile :: FilePath -> IO ()
clearFile fileName = removeFile fileName `catch` handleErr
  where
   handleErr e | isDoesNotExistError e = return ()
               | otherwise = throwIO e
