{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

-- | Tests for the compiler pipeline after L2
--
--   This is temporary and can be removed after the whole pipeline is ready
--
module Compiler where

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.TH

import System.FilePath
import System.Directory

import Gibbon.Common hiding (FunDef)
import Gibbon.DynFlags
import Gibbon.L1.Syntax hiding (FunDef, Prog, add1Prog)
import Gibbon.L2.Syntax as L2
import Gibbon.L2.Typecheck
import Gibbon.L2.Examples
import Gibbon.Passes.InferMultiplicity
import Gibbon.Passes.InferEffects
import Gibbon.Passes.RouteEnds
import Gibbon.Passes.ThreadRegions
import Gibbon.Passes.BoundsCheck
import Gibbon.Passes.Cursorize
import Gibbon.Passes.Unariser
import Gibbon.Passes.ShakeTree
import Gibbon.Passes.HoistNewBuf
import Gibbon.Passes.FindWitnesses
import Gibbon.Passes.Lower
import Gibbon.Passes.FollowRedirects
import Gibbon.Passes.RearrangeFree
import Gibbon.TargetInterp
import Gibbon.Passes.Codegen
import Gibbon.Passes.Flatten
import Gibbon.Compiler
import qualified Gibbon.L3.Typecheck as L3
import qualified Gibbon.L3.Syntax as L3
import qualified Gibbon.L4.Syntax as L4


-- | Directory to write out *.c and *.exe files
--   Relative to the gibbon-compiler dir
testDir :: FilePath
testDir = makeValid ("examples" </> "build_tmp")

-- | The compiler pipeline after inferLocations
--   It's divided into 2 functions for easy debugging. There's a good chance that we'd
--   want to inspect the output of Cursorize in most cases
runT :: Prog2 -> L3.Prog3
runT prg = fst $ defaultPackedRunPassM $ do
    l2 <- flattenL2 prg
    l2 <- inferRegScope l2
    l2 <- inferEffects l2
    l2 <- tcProg l2
    l2 <- routeEnds l2
    l2 <- tcProg l2
    l2 <- boundsCheck l2
    l2 <- threadRegions l2
    l2 <- flattenL2 l2
    l3 <- cursorize l2
    return l3


run2T :: SourceLanguage -> L3.Prog3 -> L4.Prog
run2T src l3 = fst $ defaultPackedRunPassM $ do
    l3 <- flattenL3 l3
    -- l3 <- findWitnesses l3
    -- l3 <- shakeTree l3
    l3 <- L3.tcProg True l3
    l3 <- hoistNewBuf l3
    l3 <- unariser l3
    l3 <- flattenL3 l3
    l3 <- L3.tcProg True l3
    l4 <- lower src l3
    l4 <- followRedirects l4
    rearrangeFree l4


cg :: SourceLanguage -> Prog2 -> IO String
cg src = codegenProg defaultConfig . (run2T src) . runT


type Expected = String

runner :: FilePath -> Prog2 -> Expected -> Assertion
runner fp prg exp = do
    _ <- createDirectoryIfMissing True testDir
    fp <- makeAbsolute $ testDir </> fp
    op <- cg (sourceLangFromFile fp) prg
    writeFile fp op
    res <- compileAndRunExe (defaultConfig { mode = RunExe }) fp
    let res' = init res -- strip trailing newline
    exp @=? res'

case_add1 :: Assertion
case_add1 = runner "add1.c" add1Prog "(Node (Leaf 2) (Leaf 3))"

case_copy_tree :: Assertion
case_copy_tree = runner "copytree.c" copyTreeProg "(Node (Leaf 1) (Leaf 2))"

case_copy_on_id1 :: Assertion
case_copy_on_id1 = runner "copyid1.c" copyOnId1Prog "(Node (Leaf 1) (Leaf 2))"

case_id3 :: Assertion
case_id3 = runner "id3.c" id3Prog "42"

case_int_add :: Assertion
case_int_add = runner "intAdd.c" id3Prog "42"

{-

[2018.03.18]: The unpacker isn't perfect, and may be causing this to fail.

case_node :: Assertion
case_node = runner "node.c" nodeProg "(Node (Leaf 1) (Leaf 2))"
-}

case_leaf :: Assertion
case_leaf = runner "leaf.c" leafProg "(Leaf 1)"

case_leftmost :: Assertion
case_leftmost = runner "leftmost.c" leftmostProg "1"

{- [2018.04.02]: Modified the function to not copy the left node
case_rightmost :: Assertion
case_rightmost = runner "rightmost.c" rightmostProg "2"
-}

case_buildleaf :: Assertion
case_buildleaf = runner "buildleaf.c" buildLeafProg "(Leaf 42)"

case_buildtree :: Assertion
case_buildtree = runner "buildtree.c" buildTreeProg
                 "(Node (Node (Node (Leaf 1) (Leaf 1)) (Node (Leaf 1) (Leaf 1))) (Node (Node (Leaf 1) (Leaf 1)) (Node (Leaf 1) (Leaf 1))))"

case_buildtreesum :: Assertion
case_buildtreesum = runner "buildtreesum.c" buildTreeSumProg
                 "'#(8 (Node (Node (Node (Leaf 1) (Leaf 1)) (Node (Leaf 1) (Leaf 1))) (Node (Node (Leaf 1) (Leaf 1)) (Node (Leaf 1) (Leaf 1)))))"

case_printtup :: Assertion
case_printtup = runner "printtup.c" printTupProg "'#(42 (Leaf 1))"

case_printtup2 :: Assertion
case_printtup2 = runner "printtup2.c" printTupProg2 "'#((Node (Node (Leaf 1) (Leaf 1)) (Node (Leaf 1) (Leaf 1))) (Node (Leaf 1) (Leaf 1)))"

-- case_addtrees :: Assertion
-- case_addtrees = runner "addtrees.c" addTreesProg "(Node (Node (Leaf 2) (Leaf 2)) (Node (Leaf 2) (Leaf 2)))"

case_sumtree :: Assertion
case_sumtree = runner "sumtree.c" sumTreeProg "8"

case_sumstree :: Assertion
case_sumstree = runner "sumstree.c" sumSTreeProg "8"

{-
[2018.04.04]: Changing the `isTrivial` policy for tuples and projections
caused some unexpected breakage. Unariser and Lower seem to depend on the
old policy, and programs produce incorrect output at runtime. It's strange
that they typecheck without any errors. So if we want to keep the updated
policy we cannot flatten anything after Cursorize.
See https://github.com/iu-parfunc/gibbon/issues/86.
-}
case_sumupseteven :: Assertion
case_sumupseteven = runner "sumupseteven.c" sumUpSetEvenProg "'#((Inner 8 1 (Inner 4 1 (Inner 2 1 (Leaf 1) (Leaf 1)) (Inner 2 1 (Leaf 1) (Leaf 1))) (Inner 4 1 (Inner 2 1 (Leaf 1) (Leaf 1)) (Inner 2 1 (Leaf 1) (Leaf 1)))) 8)"

-- case_subst :: Assertion
-- case_subst = runner "subst.c" substProg "(LETE 1 (VARREF 42) (VARREF 10))"

case_buildstree :: Assertion
case_buildstree = runner "buildstree.c" buildSTreeProg "(Inner 0 0 (Inner 0 0 (Inner 0 0 (Leaf 1) (Leaf 1)) (Inner 0 0 (Leaf 1) (Leaf 1))) (Inner 0 0 (Inner 0 0 (Leaf 1) (Leaf 1)) (Inner 0 0 (Leaf 1) (Leaf 1))))"

{-
case_twotrees :: Assertion
case_twotrees = runner "buildtwotrees.c" buildTwoTreesProg "'#((Node (Node (Leaf 1) (Leaf 1)) (Node (Leaf 1) (Leaf 1))) (Node (Node (Leaf 1) (Leaf 1)) (Node (Leaf 1) (Leaf 1))))"
-}

case_indrrightmost :: Assertion
case_indrrightmost = runner "indrrightmost.c" indrRightmostProg "1"

case_indrbuildtree :: Assertion
case_indrbuildtree = runner "indrbuildtree.c" indrBuildTreeProg "(Node^ (Node^ (Node^ (Leaf 1) (Leaf 1)) (Node^ (Leaf 1) (Leaf 1))) (Node^ (Node^ (Leaf 1) (Leaf 1)) (Node^ (Leaf 1) (Leaf 1))))"

case_indr_rightmost_dot_id :: Assertion
case_indr_rightmost_dot_id = runner "indrrid.c" indrIDProg "1"

case_sum_of_indr_id :: Assertion
case_sum_of_indr_id = runner "indrridsum.c" indrIDSumProg "1024"


compilerTests :: TestTree
compilerTests = $(testGroupGenerator)
