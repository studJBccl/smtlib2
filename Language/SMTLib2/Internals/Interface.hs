{- | Defines the user-accessible interface of the smtlib2 library -}
{-# LANGUAGE TypeFamilies,OverloadedStrings,FlexibleContexts #-}
module Language.SMTLib2.Internals.Interface where

import Language.SMTLib2.Internals
import Language.SMTLib2.Internals.Instances (extractAnnotation)
import Language.SMTLib2.Internals.Translation

import Data.Typeable
import Data.Text as T hiding (foldl1)
import Data.Map as Map hiding (assocs)
import Data.Array
import qualified Data.AttoLisp as L
import Data.Unit
import Data.Word
import Data.List (genericReplicate)

-- | Create a new named variable
varNamed :: (SMTType t,Typeable t,Unit (SMTAnnotation t)) => String -> SMT (SMTExpr t)
varNamed name = varNamedAnn name unit

-- | Create a named and annotated variable.
varNamedAnn :: (SMTType t,Typeable t) => String -> SMTAnnotation t -> SMT (SMTExpr t)
varNamedAnn = argVarsAnnNamed

-- | Create a annotated variable
varAnn :: (SMTType t,Typeable t) => SMTAnnotation t -> SMT (SMTExpr t)
varAnn ann = varNamedAnn "var" ann

-- | Create a fresh new variable
var :: (SMTType t,Typeable t,Unit (SMTAnnotation t)) => SMT (SMTExpr t)
var = varNamed "var"

-- | Like `argVarsAnnNamed`, but defaults the name to "var"
argVarsAnn :: Args a => ArgAnnotation a -> SMT a
argVarsAnn = argVarsAnnNamed "var"

-- | Create annotated named SMT variables of the `Args` class.
--   If more than one variable is needed, they get a numerical suffix.
argVarsAnnNamed :: Args a => String -> ArgAnnotation a -> SMT a
argVarsAnnNamed name ann = do
  (names,decl,mp) <- getSMT
  let ename = escapeName name
      namec = case Map.lookup name names of
        Nothing -> 0
        Just c -> c
      ((nc,act),res) = foldExprs
                       (\(cc,act') u ann'
                         -> let rname = T.pack $ case cc of
                                  0 -> ename
                                  _ -> ename++"_"++show cc
                                sort = getSort (getUndef u) ann'
                            in ((cc+1,act' >> (do
                                                  declareType (getUndef u) ann'
                                                  declareFun rname [] sort
                                                  mapM_ assert $ additionalConstraints (getUndef u) ann' (Var rname ann')))
                                ,Var rname ann')) (namec,return ()) undefined ann
  putSMT (Map.insert name nc names,decl,mp)
  act
  return res

-- | Like `argVarsAnn`, but can only be used for unit type annotations.
argVars :: (Args a,Unit (ArgAnnotation a)) => SMT a
argVars = argVarsAnn unit

-- | A constant expression.
constant :: (SMTValue t,Unit (SMTAnnotation t)) => t -> SMTExpr t
constant x = Const x unit

-- | An annotated constant expression.
constantAnn :: SMTValue t => t -> SMTAnnotation t -> SMTExpr t
constantAnn x ann = Const x ann

-- | Boolean conjunction
and' :: SMTLogic
and' = And

(.&&.) :: SMTExpr Bool -> SMTExpr Bool -> SMTExpr Bool
(.&&.) x y = App And [x,y]

-- | Boolean disjunction
or' :: SMTLogic
or' = Or

(.||.) :: SMTExpr Bool -> SMTExpr Bool -> SMTExpr Bool
(.||.) x y = App Or [x,y]

-- | Create a boolean expression that encodes that the array is equal to the supplied constant array.
arrayEquals :: (LiftArgs i,SMTValue v,Ix (Unpacked i),Unit (ArgAnnotation i),Unit (SMTAnnotation v)) => SMTExpr (SMTArray i v) -> Array (Unpacked i) v -> SMTExpr Bool
arrayEquals expr arr 
  = case [(select expr (liftArgs i unit)) .==. (constant v)
         | (i,v) <- assocs arr ] of
      [] -> constant True
      xs -> foldl1 (.&&.) xs

-- | Asserts that a boolean expression is true
assert :: SMTExpr Bool -> SMT ()
assert expr = putRequest $ L.List [L.Symbol "assert"
                                  ,L.toLisp expr]

-- | Set an option for the underlying SMT solver
setOption :: SMTOption -> SMT ()
setOption opt = putRequest $ L.List $ [L.Symbol "set-option"]
                ++(case opt of
                      PrintSuccess v -> [L.Symbol ":print-success"
                                        ,L.Symbol $ if v then "true" else "false"]
                      ProduceModels v -> [L.Symbol ":produce-models"
                                         ,L.Symbol $ if v then "true" else "false"]
                      ProduceProofs v -> [L.Symbol ":produce-proofs"
                                         ,L.Symbol $ if v then "true" else "false"]
                      ProduceUnsatCores v -> [L.Symbol ":produce-unsat-cores"
                                             ,L.Symbol $ if v then "true" else "false"]
                  )

-- | Create a new interpolation group
interpolationGroup :: SMT InterpolationGroup
interpolationGroup = do
  rname <- freeName "interp"
  return (InterpolationGroup rname)

-- | Create a new uniterpreted function with annotations for
--   the argument and the return type.
funAnn :: (Args a, SMTType r) => ArgAnnotation a -> SMTAnnotation r -> SMT (SMTFun a r)
funAnn = funAnnNamed "fun"

-- | Create a new uninterpreted named function with annotation for
--   the argument and the return type.
funAnnNamed :: (Args a, SMTType r) => String -> ArgAnnotation a -> SMTAnnotation r -> SMT (SMTFun a r)
funAnnNamed name annArg annRet = do
  (names,decl,mp) <- getSMT
  let func = case Map.lookup name names of
        Nothing -> 0
        Just c -> c
  putSMT (Map.insert name (func+1) names,decl,mp)
  let rname = T.pack $ (escapeName name)++(case func of
                                              0 -> ""
                                              _ -> "_"++show func)
      res = SMTFun rname annArg annRet
      
      (au,rtp) = getFunUndef res
      
      assertEq :: x -> x -> y -> y
      assertEq _ _ p = p
      
      (au2,tps,_) = createArgs annArg 0
      
  assertEq au au2 $ return ()
  declareFun rname [ l | (_,l) <- tps ] (getSort rtp annRet)
  return res

-- | funAnn with an annotation only for the return type.
funAnnRet :: (Args a, SMTType r, Unit (ArgAnnotation a)) => SMTAnnotation r -> SMT (SMTFun a r)
funAnnRet = funAnn unit

-- | Create a new uninterpreted function.
fun :: (Args a,SMTType r,SMTAnnotation r ~ (),Unit (ArgAnnotation a)) => SMT (SMTFun a r)
fun = funAnn unit unit

-- | Apply a function to an argument
app :: (SMTFunction f) => f -> SMTFunArg f -> SMTExpr (SMTFunRes f)
app = App

-- | Lift a function to arrays
map' :: (SMTFunction f,Mapable (SMTFunArg f) i) 
        => f 
        -> SMTMap f 
        (SMTFunArg f) 
        i 
        (SMTFunRes f)
map' f = SMTMap f

-- | Two expressions shall be equal
(.==.) :: SMTType a => SMTExpr a -> SMTExpr a -> SMTExpr Bool
(.==.) x y = App (Eq 2) [x,y]

infix 4 .==.

-- | Declares all arguments to be distinct
distinct :: SMTType a => [SMTExpr a] -> SMTExpr Bool
distinct = App Distinct

-- | Calculate the sum of arithmetic expressions
plus :: (SMTArith a) => SMTArithOp a
plus = Plus

-- | Calculate the product of arithmetic expressions
mult :: (SMTArith a) => SMTArithOp a
mult = Mult

-- | Subtracts two expressions
minus :: (SMTArith a) => SMTMinus a
minus = Minus

-- | Divide an arithmetic expression by another
div' :: SMTExpr Integer -> SMTExpr Integer -> SMTExpr Integer
div' x y = App Div (x,y)

div'' :: SMTIntArith
div'' = Div

-- | Perform a modulo operation on an arithmetic expression
mod' :: SMTExpr Integer -> SMTExpr Integer -> SMTExpr Integer
mod' x y = App Mod (x,y)

mod'' :: SMTIntArith
mod'' = Mod

-- | Calculate the remainder of the division of two integer expressions
rem' :: SMTExpr Integer -> SMTExpr Integer -> SMTExpr Integer
rem' x y = App Rem (x,y)

rem'' :: SMTIntArith
rem'' = Rem

-- | Divide a rational expression by another one
divide :: SMTExpr Rational -> SMTExpr Rational -> SMTExpr Rational
divide x y = App Divide (x,y)

divide' :: SMTDivide
divide' = Divide

-- | For an expression @x@, this returns the expression @-x@.
neg :: SMTArith a => SMTNeg a
neg = Neg

-- | Convert an integer expression to a real expression
toReal :: SMTExpr Integer -> SMTExpr Rational
toReal = App ToReal

-- | Convert a real expression into an integer expression
toInt :: SMTExpr Rational -> SMTExpr Integer
toInt = App ToInt

-- | If-then-else construct
ite :: (SMTType a) => SMTExpr Bool -- ^ If this expression is true
       -> SMTExpr a -- ^ Then return this expression
       -> SMTExpr a -- ^ Else this one
       -> SMTExpr a
ite c l r = App ITE (c,l,r)

-- | Exclusive or: Return true if exactly one argument is true.
xor :: SMTLogic
xor = XOr

-- | Implication
(.=>.) :: SMTExpr Bool -- ^ If this expression is true
          -> SMTExpr Bool -- ^ This one must be as well
          -> SMTExpr Bool
(.=>.) x y = App Implies [x,y]

-- | Negates a boolean expression
not' :: SMTExpr Bool -> SMTExpr Bool
not' = App Not

not'' :: SMTNot
not'' = Not

-- | Extracts an element of an array by its index
select :: (Args i,SMTType v) => SMTExpr (SMTArray i v) -> i -> SMTExpr v
select = Select

-- | The expression @store arr i v@ stores the value /v/ in the array /arr/ at position /i/ and returns the resulting new array.
store :: (Args i,SMTType v) => SMTExpr (SMTArray i v) -> i -> SMTExpr v -> SMTExpr (SMTArray i v)
store = Store

-- | Interpret a function /f/ from /i/ to /v/ as an array with indices /i/ and elements /v/.
--   Such that: @f \`app\` j .==. select (asArray f) j@ for all indices j.
asArray :: (SMTFunction f,Unit (ArgAnnotation (SMTFunArg f))) 
           => f -> SMTExpr (SMTArray (SMTFunArg f) (SMTFunRes f))
asArray f = AsArray f unit

-- | Create an array where each element is the same.
constArray :: (Args i,SMTType v) => SMTExpr v -- ^ This element will be at every index of the array
           -> ArgAnnotation i -- ^ Annotations of the index type
           -> SMTExpr (SMTArray i v)
constArray = ConstArray

-- | Bitvector and
bvand :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvand = BVAnd

-- | Bitvector or
bvor :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvor = BVOr

-- | Bitvector not
bvnot :: SMTBV t => SMTExpr t -> SMTExpr t
bvnot = BVNot

-- | Bitvector addition
bvadd :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvadd = BVAdd

-- | Bitvector subtraction
bvsub :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvsub = BVSub

-- | Bitvector multiplication
bvmul :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvmul = BVMul

-- | Bitvector unsigned remainder
bvurem :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvurem = BVURem

-- | Bitvector signed remainder
bvsrem :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvsrem = BVSRem

-- | Bitvector unsigned less-or-equal
bvule :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
bvule = BVULE

-- | Bitvector unsigned less-than
bvult :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
bvult = BVULT

-- | Bitvector unsigned greater-or-equal
bvuge :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
bvuge = BVUGE

-- | Bitvector unsigned greater-than
bvugt :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
bvugt = BVUGT

-- | Bitvector signed less-or-equal
bvsle :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
bvsle = BVSLE

-- | Bitvector signed less-than
bvslt :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
bvslt = BVSLT

-- | Bitvector signed greater-or-equal
bvsge :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
bvsge = BVSGE

-- | Bitvector signed greater-than
bvsgt :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr Bool
bvsgt = BVSGT

-- | Bitvector shift left
bvshl :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvshl = BVSHL

-- | Bitvector logical right shift
bvlshr :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvlshr = BVLSHR

-- | Bitvector arithmetical right shift
bvashr :: SMTBV t => SMTExpr t -> SMTExpr t -> SMTExpr t
bvashr = BVASHR

-- | Concats two bitvectors into one.
bvconcat :: (Concatable t1 t2,t3 ~ ConcatResult t1 t2)
            => SMTExpr t1 -> SMTExpr t2 -> SMTExpr t3
bvconcat = BVConcat

-- | Concat a list of bitvectors into one.
bvconcats :: (SMTType t1,SMTType t2,Concatable t2 t1,t2 ~ ConcatResult t2 t1)
            => [SMTExpr t1] -> SMTExpr t2
bvconcats = BVConcats

-- | Extract a sub-vector out of a given bitvector.
bvextract :: (SMTType t,Extractable t t) => Integer -- ^ The upper bound of the extracted region
          -> Integer -- ^ The lower bound of the extracted region
          -> SMTExpr t -- ^ The bitvector to extract from
          -> SMTExpr t
bvextract u l e = withUndef' $ \un -> BVExtract u l (extract' un un u l (extractAnnotation e)) e
    where
      withUndef' :: (t -> SMTExpr t) -> SMTExpr t
      withUndef' f = f undefined

-- | A more general variant of `bvextract` which can fail if the bounds are invalid.
bvextractUnsafe :: (SMTType t1,SMTType t2,Extractable t1 t2) => Integer -> Integer -> SMTExpr t1 -> SMTExpr t2
bvextractUnsafe u l e = withUndef' $ \un ->
                        BVExtract u l (extract' (getUndef e) un u l (extractAnnotation e)) e
    where
      withUndef' :: (t -> SMTExpr t) -> SMTExpr t
      withUndef' f = f undefined

-- | Safely split a 16-bit bitvector into two 8-bit bitvectors.
bvsplitu16to8 :: SMTExpr Word16 -> (SMTExpr Word8,SMTExpr Word8)
bvsplitu16to8 e = (BVExtract 15 8 () e,BVExtract 7 0 () e)

-- | Safely split a 32-bit bitvector into two 16-bit bitvectors.
bvsplitu32to16 :: SMTExpr Word32 -> (SMTExpr Word16,SMTExpr Word16)
bvsplitu32to16 e = (BVExtract 31 16 () e,BVExtract 15 0 () e)

-- | Safely split a 32-bit bitvector into four 8-bit bitvectors.
bvsplitu32to8 :: SMTExpr Word32 -> (SMTExpr Word8,SMTExpr Word8,SMTExpr Word8,SMTExpr Word8)
bvsplitu32to8 e = (BVExtract 31 24 () e,BVExtract 23 16 () e,BVExtract 15 8 () e,BVExtract 7 0 () e)

-- | Safely split a 64-bit bitvector into two 32-bit bitvectors.
bvsplitu64to32 :: SMTExpr Word64 -> (SMTExpr Word32,SMTExpr Word32)
bvsplitu64to32 e = (BVExtract 63 32 () e,BVExtract 31 0 () e)

-- | Safely split a 64-bit bitvector into four 16-bit bitvectors.
bvsplitu64to16 :: SMTExpr Word64 -> (SMTExpr Word16,SMTExpr Word16,SMTExpr Word16,SMTExpr Word16)
bvsplitu64to16 e = (BVExtract 63 48 () e,BVExtract 47 32 () e,BVExtract 31 16 () e,BVExtract 15 0 () e)

-- | Safely split a 64-bit bitvector into eight 8-bit bitvectors.
bvsplitu64to8 :: SMTExpr Word64 -> (SMTExpr Word8,SMTExpr Word8,SMTExpr Word8,SMTExpr Word8,SMTExpr Word8,SMTExpr Word8,SMTExpr Word8,SMTExpr Word8)
bvsplitu64to8 e = (BVExtract 63 56 () e,BVExtract 55 48 () e,BVExtract 47 40 () e,BVExtract 39 32 () e,BVExtract 31 24 () e,BVExtract 23 16 () e,BVExtract 15 8 () e,BVExtract 7 0 () e)

-- | If the supplied function returns true for all possible values, the forall quantification returns true.
forAll :: (Args a,Unit (ArgAnnotation a)) => (a -> SMTExpr Bool) -> SMTExpr Bool
forAll = Forall unit

-- | An annotated version of `forAll`.
forAllAnn :: Args a => ArgAnnotation a -> (a -> SMTExpr Bool) -> SMTExpr Bool
forAllAnn = Forall

-- | If the supplied function returns true for at least one possible value, the exists quantification returns true.
exists :: (Args a,Unit (ArgAnnotation a)) => (a -> SMTExpr Bool) -> SMTExpr Bool
exists = Exists unit

-- | An annotated version of `exists`.
existsAnn :: Args a => ArgAnnotation a -> (a -> SMTExpr Bool) -> SMTExpr Bool
existsAnn = Exists

-- | Binds an expression to a variable.
--   Can be used to prevent blowups in the command stream if expressions are used multiple times.
--   @let' x f@ is functionally equivalent to @f x@.
let' :: (Args a,Unit (ArgAnnotation a)) => a -> (a -> SMTExpr b) -> SMTExpr b
let' = Let unit

-- | Like `let'`, but can be given an additional type annotation for the argument of the function.
letAnn :: Args a => ArgAnnotation a -> a -> (a -> SMTExpr b) -> SMTExpr b
letAnn = Let

-- | Like 'let'', but can define multiple variables of the same type.
lets :: (Args a,Unit (ArgAnnotation a)) => [a] -> ([a] -> SMTExpr b) -> SMTExpr b
lets xs = Let (fmap (const unit) xs) xs

-- | Like 'forAll', but can quantify over more than one variable (of the same type).
forAllList :: (Args a,Unit (ArgAnnotation a)) => Integer -- ^ Number of variables to quantify
              -> ([a] -> SMTExpr Bool) -- ^ Function which takes a list of the quantified variables
              -> SMTExpr Bool
forAllList l = Forall (genericReplicate l unit)

-- | Like `exists`, but can quantify over more than one variable (of the same type).
existsList :: (Args a,Unit (ArgAnnotation a)) => Integer -- ^ Number of variables to quantify
           -> ([a] -> SMTExpr Bool) -- ^ Function which takes a list of the quantified variables
           -> SMTExpr Bool
existsList l = Exists (genericReplicate l unit)


-- | Checks if the expression is formed a specific constructor.
is :: SMTType a => SMTExpr a -> Constructor a -> SMTExpr Bool
is e con = ConTest con e

-- | Access a field of an expression
(.#) :: (SMTRecordType a,SMTType f) => SMTExpr a -> Field a f -> SMTExpr f
(.#) e f = FieldSel f e

-- | Takes the first element of a list
head' :: SMTExpr [a] -> SMTExpr a
head' = Head

-- | Drops the first element from a list
tail' :: SMTExpr [a] -> SMTExpr [a]
tail' = Tail

-- | Put a new element at the front of the list
insert' :: SMTExpr a -> SMTExpr [a] -> SMTExpr [a]
insert' = Insert

-- | Checks if a list is empty.
isNil :: SMTType a => SMTExpr [a] -> SMTExpr Bool
isNil e = is e (Constructor "nil")

-- | Checks if a list is non-empty.
isInsert :: SMTType a => SMTExpr [a] -> SMTExpr Bool
isInsert e = is e (Constructor "insert")

-- | Sets the logic used for the following program (Not needed for many solvers).
setLogic :: Text -> SMT ()
setLogic name = putRequest $ L.List [L.Symbol "set-logic"
                                    ,L.Symbol name]

-- | Given an arbitrary expression, this creates a named version of it and a name to reference it later on.
named :: (SMTType a,SMTAnnotation a ~ ()) => String -> SMTExpr a -> SMT (SMTExpr a,SMTExpr a)
named name expr = do
  rname <- freeName name
  return (Named expr rname,Var rname ())

-- | Like `named`, but defaults the name to "named".
named' :: (SMTType a,SMTAnnotation a ~ ()) => SMTExpr a -> SMT (SMTExpr a,SMTExpr a)
named' = named "named"

-- | Perform craig interpolation (<http://en.wikipedia.org/wiki/Craig_interpolation>) on the given terms and returns interpolants for them.
--   Note that not all SMT solvers support this.
getInterpolants :: [SMTExpr Bool] -> SMT [SMTExpr Bool]
getInterpolants exprs = do
  (_,tps,mp) <- getSMT
  putRequest (L.List (L.Symbol "get-interpolants":fmap (\e -> let (r,_) = exprToLisp e 0 in r) exprs))
  L.List res <- parseResponse
  return $ fmap (lispToExprT (const Nothing) tps () (\name -> mp Map.! name)) res
  
-- | After an unsuccessful 'checkSat' this method extracts a proof from the SMT solver that the instance is unsatisfiable.
getProof :: SMT (SMTExpr Bool)
getProof = do
  (_,tps,mp) <- getSMT
  let mp' = Map.union mp commonTheorems
  putRequest (L.List [L.Symbol "get-proof"])
  res <- parseResponse
  return $ lispToExprT (const Nothing) tps () (\name -> case Map.lookup name mp' of
                                                  Nothing -> error $ "Failed to find a definition for "++show name
                                                  Just n -> n
                                              ) res

-- | After an unsuccessful 'checkSat', return a list of names of named
--   expression which make the instance unsatisfiable.
getUnsatCore :: SMT [String]
getUnsatCore = do
  putRequest (L.List [L.Symbol "get-unsat-core"])
  res <- parseResponse
  case res of
    L.List names -> return $
                    fmap (\name -> case name of
                             L.Symbol s -> T.unpack s
                             _ -> error $ "Language.SMTLib2.getUnsatCore: Unknown expression "
                                  ++show name++" in core list."
                         ) names
    _ -> error $ "Language.SMTLib2.getUnsatCore: Unknown response "++show res++" to query."

-- | A map which contains signatures for a few common theorems which can be used in the proofs which 'getProof' returns.
commonTheorems :: Map T.Text TypeRep
commonTheorems = Map.fromList
  [(T.pack "|unit-resolution|",typeOf (undefined :: (Bool,Bool,Bool) -> Bool))
  ,(T.pack "|and-elim|",typeOf (undefined :: (Bool,Bool) -> Bool))
  ,(T.pack "asserted",typeOf (undefined :: Bool -> Bool))
  ,(T.pack "monotonicity",typeOf (undefined :: (Bool,Bool) -> Bool))
  ,(T.pack "trans",typeOf (undefined :: (Bool,Bool,Bool) -> Bool))
  ,(T.pack "rewrite",typeOf (undefined :: Bool -> Bool))
  ,(T.pack "mp",typeOf (undefined :: (Bool,Bool,Bool) -> Bool))
  ]