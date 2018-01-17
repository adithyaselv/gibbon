{-# LANGUAGE RecordWildCards #-}

-- |
-- Copyright   : [2015] Trevor L. McDonell
-- License     : BSD3
--

module Packed.FirstOrder.Passes.LLVM.Instruction (
    declare, getvar, getLastLocal, getfn, addTypeDef
  , instr, globalOp, localRef
  , allocate, store, load, getElemPtr, call, add, mul, sub, for, assign, phi
  , eq, neq, ult, notZeroP, ifThenElse, ptrToInt, bitcast, sext, toPtrTy
  , inttoptr, extractValue
  , int_, int32_, char_, constop_, string_
) where

-- | standard library
import Control.Monad.State
import Data.Char (ord)
import Data.Word (Word32)
import qualified Data.Map as Map
import qualified Data.Sequence as Seq

-- | llvm-general
import qualified LLVM.AST as AST
import qualified LLVM.AST.Global as G
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.Type as T
import qualified LLVM.AST.Instruction as I
import qualified LLVM.AST.CallingConvention as CC
import qualified LLVM.AST.Attribute as A
import qualified LLVM.AST.AddrSpace as AS
import qualified LLVM.AST.IntegerPredicate as IP

import Packed.FirstOrder.Passes.LLVM.Monad
import Packed.FirstOrder.Passes.LLVM.Terminator


-- | Add a definition to the module's global definitions
--
addTypeDef :: String -> AST.Definition -> CodeGen ()
addTypeDef nm d =
  modify $ \s -> s { globalTypeDefs = Map.insert nm d (globalTypeDefs s)}


-- | Add a global declaration to the symbol table
--
declare :: G.Global -> CodeGen ()
declare g =
  let name = case G.name g of
               AST.Name n   -> n
               AST.UnName n -> show n
  in
    modify $ \s -> s { globalFns = Map.insert name g (globalFns s)}


-- | Generate a fresh (un)name.
--
freshName :: CodeGen AST.Name
freshName = state $ \s@CodeGenState{..} -> ( AST.UnName next,
                                             s { next = next + 1 } )


-- | Return local var reference
--
getvar :: String -> CodeGen AST.Operand
getvar nm = do
  vars <- gets localVars
  case Map.lookup nm vars of
    Just x  -> return x
    Nothing -> error $ "Local variable not in scope: " ++ show nm


getLastLocal :: CodeGen AST.Name
getLastLocal = gets next >>= \a -> return $ AST.UnName (a - 1)


getfn :: String -> CodeGen G.Global
getfn nm = do
  fns <- gets globalFns
  case Map.lookup nm fns of
    Just x -> return x
    Nothing -> error $ "Function " ++ nm ++ " doesn't exist " ++ show fns


-- | Add an instruction to the state of the currently active block so that it is
-- computed, and return the operand (LocalReference) that can be used to later
-- refer to it.
--
instr :: T.Type -> Maybe String -> I.Instruction -> CodeGen AST.Operand
instr ty nm ins = do
  name <- case nm of
            Just x  -> do
              let ref = AST.LocalReference ty (AST.Name x)
              modify $ \s -> s { localVars = Map.insert x ref (localVars s) }
              return $ AST.Name x
            Nothing -> freshName
  instr_ $ name AST.:= ins
  return $ AST.LocalReference ty name


-- | Add raw assembly instructions to the execution stream
--
instr_ :: AST.Named AST.Instruction -> CodeGen ()
instr_ ins =
  modify $ \s ->
    case Seq.viewr (blockChain s) of
      Seq.EmptyR  -> error $ "instr_ empty block chain "  ++ show s
      bs Seq.:> b -> s { blockChain = bs Seq.|> b { instructions = instructions b Seq.|> ins } }


-- | Return a global reference pointing to an operand
--
globalOp :: T.Type -> AST.Name -> AST.Operand
globalOp ty nm = AST.ConstantOperand $ C.GlobalReference ty nm


-- | Return a local reference
--
localRef :: T.Type -> AST.Name -> AST.Operand
localRef = AST.LocalReference


-- binop (Just nm) ins x y= namedInstr T.i64 nm $ ins x y []

-- | Convert operands to the expected args format
--
toArgs :: [AST.Operand] -> [(AST.Operand, [A.ParameterAttribute])]
toArgs = map (\x -> (x, []))


-- | Allocate memory for the type
--
allocate :: T.Type -> Maybe String -> CodeGen AST.Operand
allocate ty nm = instr (toPtrTy ty) nm $ I.Alloca ty Nothing 0 []


-- | Store operand as a new local unname
--
store :: AST.Operand -> AST.Operand -> CodeGen AST.Operand
store addr val = instr T.VoidType Nothing $ I.Store False addr val Nothing 0 []
-- TODO(cskksc): dont know if T.VoidType is correct


-- | Read from memory
--

load :: T.Type -> Maybe String -> AST.Operand -> CodeGen AST.Operand
load ty nm addr = instr ty nm $ I.Load False addr Nothing 8 []


-- | Get the address of a subelement of an aggregate data structure
--
getElemPtr :: Bool -> AST.Operand -> [AST.Operand] -> CodeGen AST.Operand
getElemPtr inbounds addr idxs = instr T.i64 Nothing $ I.GetElementPtr inbounds addr idxs []
-- TODO(cskksc): dont know if T.VoidType is correct


-- | Convert value to type ty without changing any bits
bitcast :: T.Type -> Maybe String -> AST.Operand -> CodeGen AST.Operand
bitcast ty nm op = instr ty nm $ I.BitCast op ty []

-- | Convert pointer to Integer type
--
ptrToInt :: Maybe String -> AST.Operand -> CodeGen AST.Operand
ptrToInt nm x = instr T.VoidType nm $ I.PtrToInt x T.i64 []

-- | Extend value to the type ty (both integer types)
--
sext :: T.Type -> Maybe String -> AST.Operand -> CodeGen AST.Operand
sext ty nm op = instr T.VoidType nm $ I.SExt op ty []

-- |
inttoptr :: T.Type -> Maybe String -> AST.Operand -> CodeGen AST.Operand
inttoptr ty nm op = instr T.VoidType nm $ I.IntToPtr op ty []

-- | Add a function call to the execution stream
--
call :: G.Global -> Maybe String -> [AST.Operand] -> CodeGen AST.Operand
call fn varNm args = instr retTy varNm cmd
  -- TODO(cskksc): declare fn -- ^ this doesn't work
  where fn'   = globalOp retTy nm
        args' = toArgs args
        nm    = G.name fn
        retTy = G.returnType fn
        cmd   = I.Call Nothing CC.C [] (Right fn') args' [] []

-- |
extractValue :: Maybe String -> AST.Operand -> [Word32] -> CodeGen AST.Operand
extractValue nm aggr indices = instr T.VoidType nm $ I.ExtractValue aggr indices []

-- | Arithmetic operations
--

-- TODO(cskksc): handle more than 2 args

add :: Maybe String -> [AST.Operand] -> CodeGen AST.Operand
add nm [x,y] = instr T.i64 nm $ I.Add False False x y []

mul :: Maybe String -> [AST.Operand] -> CodeGen AST.Operand
mul nm [x,y] = instr T.i64 nm $ I.Mul False False x y []

sub :: Maybe String -> [AST.Operand] -> CodeGen AST.Operand
sub nm [x,y] = instr T.i64 nm $ I.Sub False False x y []


-- | Comparision and equality operators
--

icmp :: IP.IntegerPredicate -> Maybe String -> [AST.Operand] -> CodeGen AST.Operand
icmp p nm [x,y] = instr T.i64 nm $ I.ICmp p x y []

eq :: Maybe String ->  [AST.Operand] -> CodeGen AST.Operand
eq = icmp IP.EQ

neq :: Maybe String -> [AST.Operand] -> CodeGen AST.Operand
neq = icmp IP.NE

ult :: Maybe String -> [AST.Operand] -> CodeGen AST.Operand
ult = icmp IP.ULT

notZeroP :: Maybe String -> AST.Operand -> CodeGen AST.Operand
notZeroP nm op = neq nm [op, constop_ $ int_ 0]


-- | Add a phi node to the top of the current block
--
phi :: T.Type -> Maybe String -> [(AST.Operand, AST.Name)] -> CodeGen AST.Operand
phi ty nm incoming = instr ty nm $ I.Phi ty incoming []


-- | Standard if-then-else expression
--
ifThenElse :: CodeGen AST.Operand -> CodeGen BlockState -> CodeGen BlockState -> CodeGen (BlockState, BlockState)
ifThenElse test yes no = do
  ifEntry <- newBlock "if.entry"
  ifThen  <- newBlock "if.then"
  ifElse  <- newBlock "if.else"
  ifExit  <- newBlock "if.exit"

  -- check condition
  _  <- br ifEntry
  setBlock ifEntry
  p  <- test
  _  <- cbr p ifThen ifElse

  -- then block
  setBlock ifThen
  _ <- yes
  _ <- br ifExit

  -- else block
  setBlock ifElse
  _ <- no
  _ <- br ifExit

  -- exit
  setBlock ifExit
  return (ifThen, ifElse)


for :: Integer -> Integer -> AST.Operand -> CodeGen AST.Operand -> CodeGen BlockState
for start step end body = do
  forCond <- newBlock "for.cond"
  forBody <- newBlock "for.body"
  forIncr <- newBlock "for.incr"
  forExit <- newBlock "for.exit"

  -- allocate the counter
  iterV <- allocate T.i64 Nothing
  _ <- store iterV (constop_ $ int_ start)
  _ <- br forCond

  -- check the condition
  setBlock forCond
  iter <- load T.i64 Nothing iterV
  p <- ult Nothing [iter, end]
  _ <- cbr p forBody forExit

  -- execute body
  setBlock forBody
  _ <- body
  _ <- br forIncr

  -- increment the counter
  setBlock forIncr
  iter' <- load T.i64 Nothing iterV
  iterAdd <- add Nothing [iter', constop_ $ int_ step]
  _ <- store iterV iterAdd
  _ <- br forCond

  -- exit loop
  setBlock forExit
  return_


-- | ty _var_ = val
--
assign :: T.Type -> Maybe String -> AST.Operand -> CodeGen AST.Operand
assign ty nm val = do
  x <- allocate ty Nothing
  _ <- store x val
  load ty nm x


-- | Constructors for literals
--

constop_ :: C.Constant -> AST.Operand
constop_ = AST.ConstantOperand

int_ :: Integer -> C.Constant
int_ = C.Int 64

int32_ :: Integer -> C.Constant
int32_ = C.Int 32

char_ :: Char -> C.Constant
char_ = C.Int 8 . toInteger . ord

string_ :: String -> C.Constant
string_ = C.Array T.i8 . map char_


-- | Convert the type to a pointer type
--
toPtrTy :: T.Type -> T.Type
toPtrTy ty = T.PointerType ty (AS.AddrSpace 0)
