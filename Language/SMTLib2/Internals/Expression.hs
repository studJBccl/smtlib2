module Language.SMTLib2.Internals.Expression where

import Language.SMTLib2.Internals.Type hiding (Field)
import Language.SMTLib2.Internals.Type.Nat

import Data.Proxy
import Data.Typeable
import Numeric
import Text.Show
import Data.List (genericLength,genericReplicate)
import Data.GADT.Compare
import Data.GADT.Show
import Data.Type.Equality

class (Liftable arg,GetType (SameType arg)) => AllEq (arg::[Type]) where
  type SameType arg :: Type
  allEqToList :: Args e arg -> [e (SameType arg)]

instance GetType t => AllEq '[t] where
  type SameType '[t] = t
  allEqToList (Arg e NoArg) = [e]
instance (GetType a,AllEq (a ': b),SameType (a ': b) ~ a) => AllEq (a ': a ': b) where
  type SameType (a ': a ': b) = a
  allEqToList (Arg e1 rest)
    = e1:allEqToList rest

data Function (fun :: [Type] -> Type -> *) (con :: [Type] -> * -> *) (field :: * -> Type -> *) (arg :: [Type]) (res :: Type) where
  Fun :: (GetTypes arg,GetType res) => fun arg res -> Function fun con field arg res
  Eq :: AllEq arg => Function fun con field arg BoolType
  Distinct :: AllEq arg => Function fun con field arg BoolType
  Map :: (Liftable arg,GetType res,GetTypes idx)
      => Function fun con field arg res
      -> Function fun con field (Lifted arg idx) (ArrayType idx res)
  OrdInt :: OrdOp -> Function fun con field '[IntType,IntType] BoolType
  OrdReal :: OrdOp -> Function fun con field '[RealType,RealType] BoolType
  ArithInt :: (AllEq arg, SameType arg ~ IntType)
           => ArithOp -> Function fun con field arg IntType
  ArithReal :: (AllEq arg, SameType arg ~ RealType) => ArithOp -> Function fun field con arg RealType
  ArithIntBin :: ArithOpInt -> Function fun con field '[IntType,IntType] IntType
  Divide :: Function fun con field '[RealType,RealType] RealType
  AbsInt :: Function fun con field '[IntType] IntType
  AbsReal :: Function fun con field '[RealType] RealType
  Not :: Function fun con field '[BoolType] BoolType
  Logic :: (AllEq arg, SameType arg ~ BoolType) => LogicOp -> Function fun con field arg BoolType
  ToReal :: Function fun con field '[IntType] RealType
  ToInt :: Function fun con field '[RealType] IntType
  ITE :: GetType a => Function fun con field '[BoolType,a,a] a
  BVComp :: KnownNat a => BVCompOp -> Function fun con field '[BitVecType a,BitVecType a] BoolType
  BVBin :: KnownNat a => BVBinOp -> Function fun con field '[BitVecType a,BitVecType a] (BitVecType a)
  BVUn :: KnownNat a => BVUnOp -> Function fun con field '[BitVecType a] (BitVecType a)
  Select :: (GetTypes idx,GetType val)
         => Function fun con field (ArrayType idx val ': idx) val
  Store :: (GetTypes idx,GetType val)
        => Function fun con field (ArrayType idx val ': val ': idx)
                                  (ArrayType idx val)
  ConstArray :: (GetTypes idx,GetType val)
             => Function fun con field '[val] (ArrayType idx val)
  Concat :: (KnownNat n1,KnownNat n2)
         => Function fun con field '[BitVecType n1,BitVecType n2]
            (BitVecType (n1 + n2))
  Extract :: (KnownNat start,KnownNat len,KnownNat a,((start + len) <= a) ~ True)
          => Proxy start -> Function fun con field '[BitVecType a] (BitVecType len)
  Constructor :: IsDatatype a => con arg a -> Function fun con field arg (DataType a)
  Test :: (GetTypes arg,IsDatatype a) => con arg a -> Function fun con field '[DataType a] BoolType
  Field :: IsDatatype a => field a t -> Function fun con field '[DataType a] t
  Divisible :: Integer -> Function fun con field '[IntType] BoolType

data AnyFunction (fun :: [Type] -> Type -> *) (con :: [Type] -> * -> *) (field :: * -> Type -> *) where
  AnyFunction :: (Liftable arg,GetType t) => Function fun con field arg t -> AnyFunction fun con field

data OrdOp = Ge | Gt | Le | Lt deriving (Eq,Ord,Show)

data ArithOp = Plus | Mult | Minus deriving (Eq,Ord,Show)

data ArithOpInt = Div | Mod | Rem deriving (Eq,Ord,Show)

data LogicOp = And | Or | XOr | Implies deriving (Eq,Ord,Show)

data BVCompOp = BVULE
              | BVULT
              | BVUGE
              | BVUGT
              | BVSLE
              | BVSLT
              | BVSGE
              | BVSGT
              deriving (Eq,Ord,Show)

data BVBinOp = BVAdd
             | BVSub
             | BVMul
             | BVURem
             | BVSRem
             | BVUDiv
             | BVSDiv
             | BVSHL
             | BVLSHR
             | BVASHR
             | BVXor
             | BVAnd
             | BVOr
             deriving (Eq,Ord,Show)

data BVUnOp = BVNot | BVNeg deriving (Eq,Ord,Show)

data LetBinding (v :: Type -> *) (e :: Type -> *) (t :: Type)
  = LetBinding { letVar :: v t
               , letExpr :: e t }

data Quantifier = Forall | Exists deriving (Typeable,Eq,Ord,Show)

data Expression (v :: Type -> *) (qv :: Type -> *) (fun :: [Type] -> Type -> *) (con :: [Type] -> * -> *) (field :: * -> Type -> *) (fv :: Type -> *) (e :: Type -> *) (res :: Type) where
  Var :: v res -> Expression v qv fun con field fv e res
  QVar :: qv res -> Expression v qv fun con field fv e res
  FVar :: fv res -> Expression v qv fun con field fv e res
  App :: (GetTypes arg,GetType res)
      => Function fun con field arg res
      -> Args e arg
      -> Expression v qv fun con field fv e res
  Const :: Value con a -> Expression v qv fun con field fv e a
  AsArray :: (GetTypes arg,GetType res)
          => Function fun con field arg res
          -> Expression v qv fun con field fv e (ArrayType arg res)
  Quantification :: GetTypes arg => Quantifier -> Args qv arg -> e BoolType
                 -> Expression v qv fun con field fv e BoolType
  Let :: GetTypes arg
      => Args (LetBinding v e) arg
      -> e res
      -> Expression v qv fun con field fv e res

instance (GEq2 fun,GEq2 con,GEq2 field)
         => Eq (Function fun con field arg res) where
  (==) x y = case geqXX x y of
     Just _ -> True
     _ -> False

allEqOfList :: GetType t => Proxy t
            -> Integer
            -> (forall arg. (AllEq (t ': arg),SameType (t ': arg) ~ t)
                => Proxy (t ': arg) -> a)
            -> a
allEqOfList (_::Proxy t) 1 f = f (Proxy::Proxy ('[t]::[Type]))
allEqOfList pr@(_::Proxy t) n f
  = allEqOfList pr (n-1) $
    \(_::Proxy (t ': ts)) -> f (Proxy::Proxy (t ': t ': ts))

functionType :: (GetTypes arg,GetType res) => Function fun con field arg res -> (Args Repr arg,Repr res)
functionType (_::Function fun con field arg res) = (getTypes (Proxy::Proxy arg),getType (Proxy::Proxy res))

mapExpr :: (Functor m,Monad m,GetType r,Typeable con2)
        => (forall t. GetType t => v1 t -> m (v2 t))
        -> (forall t. GetType t => qv1 t -> m (qv2 t))
        -> (forall arg t. (GetTypes arg,GetType t) => fun1 arg t -> m (fun2 arg t))
        -> (forall arg t. (GetTypes arg) => con1 arg t -> m (con2 arg t))
        -> (forall t res. GetType res => field1 t res -> m (field2 t res))
        -> (forall t. GetType t => fv1 t -> m (fv2 t))
        -> (forall t. GetType t => e1 t -> m (e2 t))
        -> Expression v1 qv1 fun1 con1 field1 fv1 e1 r
        -> m (Expression v2 qv2 fun2 con2 field2 fv2 e2 r)
mapExpr f _ _ _ _ _ _ (Var v) = fmap Var (f v)
mapExpr _ f _ _ _ _ _ (QVar v) = fmap QVar (f v)
mapExpr _ _ _ _ _ f _ (FVar v) = fmap FVar (f v)
mapExpr _ _ f g h _ i (App fun args) = do
  fun' <- mapFunction f g h fun
  args' <- mapArgs i args
  return (App fun' args')
mapExpr _ _ _ f _ _ _ (Const val) = fmap Const (mapValue f val)
mapExpr _ _ f g h _ _ (AsArray fun) = fmap AsArray (mapFunction f g h fun)
mapExpr _ f _ _ _ _ g (Quantification q args body) = do
  args' <- mapArgs f args
  body' <- g body
  return (Quantification q args' body')
mapExpr f _ _ _ _ _ g (Let args body) = do
  args' <- mapArgs (\bind -> do
                      nv <- f (letVar bind)
                      nexpr <- g (letExpr bind)
                      return $ LetBinding nv nexpr
                   ) args
  body' <- g body
  return (Let args' body')

mapFunction :: (Functor m,Monad m,GetTypes arg,GetType res)
            => (forall arg t. (GetTypes arg,GetType t) => fun1 arg t -> m (fun2 arg t))
            -> (forall arg t. (GetTypes arg) => con1 arg t -> m (con2 arg t))
            -> (forall t res. (GetType res) => field1 t res -> m (field2 t res))
            -> Function fun1 con1 field1 arg res
            -> m (Function fun2 con2 field2 arg res)
mapFunction f _ _ (Fun x) = fmap Fun (f x)
mapFunction _ _ _ Eq = return Eq
mapFunction _ _ _ Distinct = return Distinct
mapFunction f g h (Map x) = do
  x' <- mapFunction f g h x
  return (Map x')
mapFunction _ _ _ (OrdInt op) = return (OrdInt op)
mapFunction _ _ _ (OrdReal op) = return (OrdReal op)
mapFunction _ _ _ (ArithInt op) = return (ArithInt op)
mapFunction _ _ _ (ArithReal op) = return (ArithReal op)
mapFunction _ _ _ (ArithIntBin op) = return (ArithIntBin op)
mapFunction _ _ _ Divide = return Divide
mapFunction _ _ _ AbsInt = return AbsInt
mapFunction _ _ _ AbsReal = return AbsReal
mapFunction _ _ _ Not = return Not
mapFunction _ _ _ (Logic op) = return (Logic op)
mapFunction _ _ _ ToReal = return ToReal
mapFunction _ _ _ ToInt = return ToInt
mapFunction _ _ _ ITE = return ITE
mapFunction _ _ _ (BVComp op) = return (BVComp op)
mapFunction _ _ _ (BVBin op) = return (BVBin op)
mapFunction _ _ _ (BVUn op) = return (BVUn op)
mapFunction _ _ _ Select = return Select
mapFunction _ _ _ Store = return Store
mapFunction _ _ _ ConstArray = return ConstArray
mapFunction _ _ _ Concat = return Concat
mapFunction _ _ _ (Extract start) = return (Extract start)
mapFunction _ f _ (Constructor con) = fmap Constructor (f con)
mapFunction _ f _ (Test con) = fmap Test (f con)
mapFunction _ _ f (Field x) = fmap Field (f x)
mapFunction _ _ _ (Divisible x) = return (Divisible x)

allEqFromList :: GetType t => [e t]
              -> (forall arg. (AllEq (t ': arg),SameType (t ': arg) ~ t) => Args e (t ': arg) -> a)
              -> a
allEqFromList [e] f = f (Arg e NoArg)
allEqFromList (x:xs) f = allEqFromList xs $
                         \xs' -> f (Arg x xs')

instance (GShow v,GShow qv,GShow2 fun,GShow2 con,GShow2 field,GShow fv,GShow e)
         => Show (Expression v qv fun con field fv e r) where
  showsPrec p (Var v) = showParen (p>10) $
                        showString "Var " .
                        gshowsPrec 11 v
  showsPrec p (QVar v) = showParen (p>10) $
                         showString "QVar " .
                         gshowsPrec 11 v
  showsPrec p (FVar v) = showParen (p>10) $
                         showString "FVar " .
                         gshowsPrec 11 v
  showsPrec p (App fun args)
    = showParen (p>10) $
      showString "App " .
      showsPrec 11 fun .
      showChar ' ' .
      showListWith id (argsToList (gshowsPrec 0) args)
  showsPrec p (Const val) = showsPrec p val
  showsPrec p (AsArray fun)
    = showParen (p>10) $
      showString "AsArray " .
      showsPrec 11 fun
  showsPrec p (Quantification q args body)
    = showParen (p>10) $
      showsPrec 11 q .
      showListWith id (argsToList (gshowsPrec 0) args) .
      showChar ' ' .
      gshowsPrec 11 body
  showsPrec p (Let args body)
    = showParen (p>10) $
      showString "Let " .
      showListWith id (argsToList
                       (\(LetBinding v e)
                        -> (gshowsPrec 10 v) . showChar '=' . (gshowsPrec 10 e)
                      ) args)  .
      showChar ' ' .
      gshowsPrec 10 body

instance (GShow v,GShow qv,GShow2 fun,GShow2 con,GShow2 field,GShow fv,GShow e)
         => GShow (Expression v qv fun con field fv e) where
  gshowsPrec = showsPrec

instance (GShow2 fun,GShow2 con,GShow2 field)
         => Show (Function fun con field arg res) where
  showsPrec p (Fun x) = gshowsPrec2 p x
  showsPrec _ Eq = showString "Eq"
  showsPrec _ Distinct = showString "Distinct"
  showsPrec p (Map x) = showParen (p>10) $
                        showString "Map " .
                        showsPrec 11 x
  showsPrec p (OrdInt op) = showParen (p>10) $
                            showString "OrdInt " .
                            showsPrec 11 op
  showsPrec p (OrdReal op) = showParen (p>10) $
                             showString "OrdReal " .
                             showsPrec 11 op
  showsPrec p (ArithInt op) = showParen (p>10) $
                              showString "ArithInt " .
                              showsPrec 11 op
  showsPrec p (ArithReal op) = showParen (p>10) $
                               showString "ArithReal " .
                               showsPrec 11 op
  showsPrec p (ArithIntBin op) = showParen (p>10) $
                                 showString "ArithIntBin " .
                                 showsPrec 11 op
  showsPrec p Divide = showString "Divide"
  showsPrec p AbsInt = showString "AbsInt"
  showsPrec p AbsReal = showString "AbsReal"
  showsPrec _ Not =  showString "Not"
  showsPrec p (Logic op) = showParen (p>10) $
                           showString "Logic " .
                           showsPrec 11 op
  showsPrec _ ToReal = showString "ToReal"
  showsPrec _ ToInt = showString "ToInt"
  showsPrec _ ITE = showString "ITE"
  showsPrec p (BVComp op) = showParen (p>10) $
                            showString "BVComp " .
                            showsPrec 11 op
  showsPrec p (BVBin op) = showParen (p>10) $
                           showString "BVBin " .
                           showsPrec 11 op
  showsPrec _ Select = showString "Select"
  showsPrec _ Store = showString "Store"
  showsPrec _ ConstArray = showString "ConstArray"
  showsPrec _ Concat = showString "Concat"
  showsPrec p (Extract pr) = showParen (p>10) $
                             showString "Extract " .
                             showsPrec 11 (natVal pr)
  showsPrec p (Constructor con) = showParen (p>10) $
                                  showString "Constructor " .
                                  gshowsPrec2 11 con
  showsPrec p (Test con) = showParen (p>10) $
                           showString "Test " .
                           gshowsPrec2 11 con
  showsPrec p (Field x) = showParen (p>10) $
                          showString "Field " .
                          gshowsPrec2 11 x
  showsPrec p (Divisible x) = showParen (p>10) $
                              showString "Divisible " .
                              showsPrec 11 x

instance (GShow2 fun,GShow2 con,GShow2 field)
         => GShow2 (Function fun con field) where
  gshowsPrec2 = showsPrec

instance (GEq v,GEq e) => GEq (LetBinding v e) where
  geq (LetBinding v1 e1) (LetBinding v2 e2) = do
    Refl <- geq v1 v2
    geq e1 e2

instance (GCompare v,GCompare e) => GCompare (LetBinding v e) where
  gcompare (LetBinding v1 e1) (LetBinding v2 e2) = case gcompare v1 v2 of
    GEQ -> gcompare e1 e2
    r -> r

instance (GEq v,GEq qv,GEq2 fun,GEq2 con,GEq2 field,GEq fv,GEq e)
         => GEq (Expression v qv fun con field fv e) where
  geq (Var v1) (Var v2) = geq v1 v2
  geq (QVar v1) (QVar v2) = geq v1 v2
  geq (FVar v1) (FVar v2) = geq v1 v2
  geq (App f1 arg1) (App f2 arg2) = do
    (Refl,Refl) <- geqXX f1 f2
    Refl <- geq arg1 arg2
    return Refl
  geq (Const x) (Const y) = geq x y
  geq (AsArray f1) (AsArray f2) = do
    (Refl,Refl) <- geqXX f1 f2
    return Refl
  geq (Quantification q1 arg1 body1) (Quantification q2 arg2 body2)
    | q1==q2 = do
        Refl <- geq arg1 arg2
        geq body1 body2
    | otherwise = Nothing
  geq (Let bnd1 body1) (Let bnd2 body2) = do
    Refl <- geq bnd1 bnd2
    geq body1 body2
  geq _ _ = Nothing

instance (GCompare v,GCompare qv,GCompare2 fun,GCompare2 con,
          GCompare2 field,GCompare fv,GCompare e)
         => GCompare (Expression v qv fun con field fv e) where
  gcompare (Var v1) (Var v2) = gcompare v1 v2
  gcompare (Var _) _ = GLT
  gcompare _ (Var _) = GGT
  gcompare (QVar v1) (QVar v2) = gcompare v1 v2
  gcompare (QVar _) _ = GLT
  gcompare _ (QVar _) = GGT
  gcompare (FVar v1) (FVar v2) = gcompare v1 v2
  gcompare (FVar _) _ = GLT
  gcompare _ (FVar _) = GGT
  gcompare (App f1 arg1) (App f2 arg2) = case gcompareXX f1 f2 of
    GEQ2 -> GEQ
    GLT2 -> GLT
    GGT2 -> GGT
  gcompare (App _ _) _ = GLT
  gcompare _ (App _ _) = GGT
  gcompare (Const v1) (Const v2) = gcompare v1 v2
  gcompare (Const _) _ = GLT
  gcompare _ (Const _) = GGT
  gcompare (AsArray f1) (AsArray f2) = case gcompareXX f1 f2 of
    GEQ2 -> GEQ
    GLT2 -> GLT
    GGT2 -> GGT
  gcompare (AsArray _) _ = GLT
  gcompare _ (AsArray _) = GGT
  gcompare (Quantification q1 arg1 body1) (Quantification q2 arg2 body2) = case compare q1 q2 of
    LT -> GLT
    GT -> GGT
    EQ -> case gcompare arg1 arg2 of
      GEQ -> gcompare body1 body2
      GLT -> GLT
      GGT -> GGT
  gcompare (Quantification _ _ _) _ = GLT
  gcompare _ (Quantification _ _ _) = GGT
  gcompare (Let bnd1 body1) (Let bnd2 body2) = case gcompare bnd1 bnd2 of
    GEQ -> gcompare body1 body2
    GLT -> GLT
    GGT -> GGT

instance (GEq2 fun,GEq2 con,GEq2 field) => GEq2 (Function fun con field) where
  geqXX (Fun f1) (Fun f2) = geqXX f1 f2
  geqXX (Eq::Function fun con field arg1 r1) (Eq::Function fun con field arg2 r2) = do
    Refl <- eqT :: Maybe (arg1 :~: arg2)
    return (Refl,Refl)
  geqXX (Distinct::Function fun con field arg1 r1) (Distinct::Function fun con field arg2 r2) = do
    Refl <- eqT :: Maybe (arg1 :~: arg2)
    return (Refl,Refl)
  geqXX m1@(Map f1) m2@(Map f2) = do
    (Refl,Refl) <- geqXX f1 f2
    case m1 of
      (_::Function fun con field a1 (ArrayType idx1 res1)) -> case m2 of
        (_::Function fun con field a2 (ArrayType idx2 res2)) -> do
          Refl <- eqT :: Maybe (idx1 :~: idx2)
          return (Refl,Refl)
  geqXX (OrdInt o1) (OrdInt o2) = if o1==o2 then Just (Refl,Refl) else Nothing
  geqXX (OrdReal o1) (OrdReal o2) = if o1==o2 then Just (Refl,Refl) else Nothing
  geqXX f1@(ArithInt o1) f2@(ArithInt o2)
    = if o1==o2
      then case f1 of
        (_::Function fun con field arg1 IntType) -> case f2 of
          (_::Function fun con field arg2 IntType) -> do
            Refl <- eqT :: Maybe (arg1 :~: arg2)
            return (Refl,Refl)
      else Nothing
  geqXX f1@(ArithReal o1) f2@(ArithReal o2)
    = if o1==o2
      then case f1 of
        (_::Function fun con field arg1 RealType) -> case f2 of
          (_::Function fun con field arg2 RealType) -> do
            Refl <- eqT :: Maybe (arg1 :~: arg2)
            return (Refl,Refl)
      else Nothing
  geqXX (ArithIntBin o1) (ArithIntBin o2) = if o1==o2 then Just (Refl,Refl) else Nothing
  geqXX Divide Divide = Just (Refl,Refl)
  geqXX AbsInt AbsInt = Just (Refl,Refl)
  geqXX AbsReal AbsReal = Just (Refl,Refl)
  geqXX Not Not = Just (Refl,Refl)
  geqXX f1@(Logic o1) f2@(Logic o2)
    = if o1==o2
      then case f1 of
        (_::Function fun con field arg1 BoolType) -> case f2 of
          (_::Function fun con field arg2 BoolType) -> do
            Refl <- eqT :: Maybe (arg1 :~: arg2)
            return (Refl,Refl)
      else Nothing
  geqXX ToReal ToReal = Just (Refl,Refl)
  geqXX ToInt ToInt = Just (Refl,Refl)
  geqXX f1@ITE f2@ITE = case f1 of
    (_::Function fun con field [BoolType,t1,t1] t1) -> case f2 of
      (_::Function fun con field [BoolType,t2,t2] t2) -> do
        Refl <- eqT :: Maybe (t1 :~: t2)
        return (Refl,Refl)
  geqXX f1@(BVComp o1) f2@(BVComp o2)
    = if o1==o2
      then case f1 of
        (_::Function fun con field [BitVecType t1,BitVecType t1] BoolType) -> case f2 of
          (_::Function fun con field [BitVecType t2,BitVecType t2] BoolType) -> do
            Refl <- eqT :: Maybe (t1 :~: t2)
            return (Refl,Refl)
      else Nothing
  geqXX f1@(BVBin o1) f2@(BVBin o2)
    = if o1==o2
      then case f1 of
        (_::Function fun con field [BitVecType t1,BitVecType t1] (BitVecType t1)) -> case f2 of
          (_::Function fun con field [BitVecType t2,BitVecType t2] (BitVecType t2)) -> do
            Refl <- eqT :: Maybe (t1 :~: t2)
            return (Refl,Refl)
      else Nothing
  geqXX f1@(BVUn o1) f2@(BVUn o2)
    = if o1==o2
      then case f1 of
        (_::Function fun con field '[BitVecType t1] (BitVecType t1)) -> case f2 of
          (_::Function fun con field '[BitVecType t2] (BitVecType t2)) -> do
            Refl <- eqT :: Maybe (t1 :~: t2)
            return (Refl,Refl)
      else Nothing
  geqXX f1@Select f2@Select
    = case f1 of
      (_::Function fun con field (ArrayType idx1 val1 ': idx1) val1) -> case f2 of
        (_::Function fun con field (ArrayType idx2 val2 ': idx2) val2) -> do
          Refl <- eqT :: Maybe (idx1 :~: idx2)
          Refl <- eqT :: Maybe (val1 :~: val2)
          return (Refl,Refl)
  geqXX f1@Store f2@Store
    = case f1 of
      (_::Function fun con field (ArrayType idx1 val1 ': val1 ': idx1) (ArrayType idx1 val1)) -> case f2 of
        (_::Function fun con field (ArrayType idx2 val2 ': val2 ': idx2) (ArrayType idx2 val2)) -> do
          Refl <- eqT :: Maybe (idx1 :~: idx2)
          Refl <- eqT :: Maybe (val1 :~: val2)
          return (Refl,Refl)
  geqXX f1@ConstArray f2@ConstArray = case f1 of
    (_::Function fun con field '[val1] (ArrayType idx1 val1)) -> case f2 of
      (_::Function fun con field '[val2] (ArrayType idx2 val2)) -> do
         Refl <- eqT :: Maybe (idx1 :~: idx2)
         Refl <- eqT :: Maybe (val1 :~: val2)
         return (Refl,Refl)
  geqXX f1@Concat f2@Concat = case f1 of
    (_::Function fun con field '[BitVecType a1,BitVecType b1] (BitVecType (a1+b1))) -> case f2 of
      (_::Function fun con field '[BitVecType a2,BitVecType b2] (BitVecType (a2+b2))) -> do
        Refl <- eqT :: Maybe (a1 :~: a2)
        Refl <- eqT :: Maybe (b1 :~: b2)
        return (Refl,Refl)
  geqXX f1@(Extract (_::Proxy s1)) f2@(Extract (_::Proxy s2)) = do
    Refl <- eqT :: Maybe (s1 :~: s2)
    case f1 of
      (_::Function fun con field '[BitVecType a1] (BitVecType len1)) -> case f2 of
        (_::Function fun con field '[BitVecType a2] (BitVecType len2)) -> do
          Refl <- eqT :: Maybe (a1 :~: a2)
          Refl <- eqT :: Maybe (len1 :~: len2)
          return (Refl,Refl)
  geqXX (Constructor c1) (Constructor c2) = do
    (Refl,Refl) <- geqXX c1 c2
    return (Refl,Refl)
  geqXX (Test c1) (Test c2) = do
    (Refl,Refl) <- geqXX c1 c2
    return (Refl,Refl)
  geqXX (Field f1) (Field f2) = do
    (Refl,Refl) <- geqXX f1 f2
    return (Refl,Refl)
  geqXX (Divisible n1) (Divisible n2) = if n1==n2 then Just (Refl,Refl) else Nothing
  geqXX _ _ = Nothing

instance (GCompare2 fun,GCompare2 con,GCompare2 field)
         => GCompare2 (Function fun con field) where
  gcompareXX (Fun x) (Fun y) = gcompareXX x y
  gcompareXX (Fun _) _ = GLT2
  gcompareXX _ (Fun _) = GGT2
  gcompareXX f1@Eq f2@Eq = case f1 of
    (_::Function fun con field arg1 BoolType) -> case f2 of
      (_::Function fun con field arg2 BoolType)
        -> case gcompare (getTypes (Proxy::Proxy arg1))
                         (getTypes (Proxy::Proxy arg2)) of
             GEQ -> GEQ2
             GLT -> GLT2
             GGT -> GGT2
  gcompareXX Eq _ = GLT2
  gcompareXX _ Eq = GGT2
  gcompareXX f1@Distinct f2@Distinct = case f1 of
    (_::Function fun con field arg1 BoolType) -> case f2 of
      (_::Function fun con field arg2 BoolType)
        -> case gcompare (getTypes (Proxy::Proxy arg1))
                         (getTypes (Proxy::Proxy arg2)) of
             GEQ -> GEQ2
             GLT -> GLT2
             GGT -> GGT2
  gcompareXX Distinct _ = GLT2
  gcompareXX _ Distinct = GGT2
  gcompareXX m1@(Map f1) m2@(Map f2) = case gcompareXX f1 f2 of
    GEQ2 -> case m1 of
      (_::Function fun con field arg1 (ArrayType idx1 res)) -> case m2 of
        (_::Function fun con field arg2 (ArrayType idx2 res))
          -> case gcompare (getTypes (Proxy::Proxy idx1))
                           (getTypes (Proxy::Proxy idx2)) of
               GEQ -> GEQ2
               GLT -> GLT2
               GGT -> GGT2
    GLT2 -> GLT2
    GGT2 -> GGT2
  gcompareXX (Map _) _ = GLT2
  gcompareXX _ (Map _) = GGT2
  gcompareXX (OrdInt o1) (OrdInt o2) = case compare o1 o2 of
    EQ -> GEQ2
    LT -> GLT2
    GT -> GGT2
  gcompareXX (OrdInt _) _ = GLT2
  gcompareXX _ (OrdInt _) = GGT2
  gcompareXX (OrdReal o1) (OrdReal o2) = case compare o1 o2 of
    EQ -> GEQ2
    LT -> GLT2
    GT -> GGT2
  gcompareXX (OrdReal _) _ = GLT2
  gcompareXX _ (OrdReal _) = GGT2
  gcompareXX f1@(ArithInt o1) f2@(ArithInt o2) = case compare o1 o2 of
    EQ -> case f1 of
      (_::Function fun con field arg1 IntType) -> case f2 of
        (_::Function fun con field arg2 IntType)
          -> case gcompare (getTypes (Proxy::Proxy arg1))
                           (getTypes (Proxy::Proxy arg2)) of
               GEQ -> GEQ2
               GLT -> GLT2
               GGT -> GGT2
    LT -> GLT2
    GT -> GGT2
  gcompareXX (ArithInt _) _ = GLT2
  gcompareXX _ (ArithInt _) = GGT2
  gcompareXX f1@(ArithReal o1) f2@(ArithReal o2) = case compare o1 o2 of
    EQ -> case f1 of
      (_::Function fun con field arg1 RealType) -> case f2 of
        (_::Function fun con field arg2 RealType)
          -> case gcompare (getTypes (Proxy::Proxy arg1))
                           (getTypes (Proxy::Proxy arg2)) of
               GEQ -> GEQ2
               GLT -> GLT2
               GGT -> GGT2
    LT -> GLT2
    GT -> GGT2
  gcompareXX (ArithReal _) _ = GLT2
  gcompareXX _ (ArithReal _) = GGT2
  gcompareXX (ArithIntBin o1) (ArithIntBin o2) = case compare o1 o2 of
    EQ -> GEQ2
    LT -> GLT2
    GT -> GGT2
  gcompareXX (ArithIntBin _) _ = GLT2
  gcompareXX _ (ArithIntBin _) = GGT2
  gcompareXX Divide Divide = GEQ2
  gcompareXX Divide _ = GLT2
  gcompareXX _ Divide = GGT2
  gcompareXX AbsInt AbsInt = GEQ2
  gcompareXX AbsInt _ = GLT2
  gcompareXX _ AbsInt = GGT2
  gcompareXX AbsReal AbsReal = GEQ2
  gcompareXX AbsReal _ = GLT2
  gcompareXX _ AbsReal = GGT2
  gcompareXX Not Not = GEQ2
  gcompareXX Not _ = GLT2
  gcompareXX _ Not = GGT2
  gcompareXX f1@(Logic o1) f2@(Logic o2) = case compare o1 o2 of
    EQ -> case f1 of
      (_::Function fun con field arg1 BoolType) -> case f2 of
        (_::Function fun con field arg2 BoolType)
          -> case gcompare (getTypes (Proxy::Proxy arg1))
                           (getTypes (Proxy::Proxy arg2)) of
               GEQ -> GEQ2
               GLT -> GLT2
               GGT -> GGT2
    LT -> GLT2
    GT -> GGT2
  gcompareXX (Logic _) _ = GLT2
  gcompareXX _ (Logic _) = GGT2
  gcompareXX ToReal ToReal = GEQ2
  gcompareXX ToReal _ = GLT2
  gcompareXX _ ToReal = GGT2
  gcompareXX ToInt ToInt = GEQ2
  gcompareXX ToInt _ = GLT2
  gcompareXX _ ToInt = GGT2
  gcompareXX f1@ITE f2@ITE = case f1 of
    (_::Function fun con field [BoolType,a,a] a) -> case f2 of
      (_::Function fun con field [BoolType,b,b] b)
        -> case gcompare (getType (Proxy::Proxy a))
                         (getType (Proxy::Proxy b)) of
             GEQ -> GEQ2
             GLT -> GLT2
             GGT -> GGT2
  gcompareXX ITE _ = GLT2
  gcompareXX _ ITE = GGT2
  gcompareXX f1@(BVComp o1) f2@(BVComp o2) = case compare o1 o2 of
    EQ -> case f1 of
      (_::Function fun con field [BitVecType n1,BitVecType n1] BoolType) -> case f2 of
        (_::Function fun con field [BitVecType n2,BitVecType n2] BoolType)
          -> case compareNat (Proxy::Proxy n1) (Proxy::Proxy n2) of
               GEQ -> GEQ2
               GLT -> GLT2
               GGT -> GGT2
    LT -> GLT2
    GT -> GGT2
  gcompareXX (BVComp _) _ = GLT2
  gcompareXX _ (BVComp _) = GGT2
  gcompareXX f1@(BVBin o1) f2@(BVBin o2) = case compare o1 o2 of
    EQ -> case f1 of
      (_::Function fun con field [BitVecType n1,BitVecType n1] (BitVecType n1)) -> case f2 of
        (_::Function fun con field [BitVecType n2,BitVecType n2] (BitVecType n2))
          -> case compareNat (Proxy::Proxy n1) (Proxy::Proxy n2) of
               GEQ -> GEQ2
               GLT -> GLT2
               GGT -> GGT2
    LT -> GLT2
    GT -> GGT2
  gcompareXX (BVBin _) _ = GLT2
  gcompareXX _ (BVBin _) = GGT2
  gcompareXX f1@(BVUn o1) f2@(BVUn o2) = case compare o1 o2 of
    EQ -> case f1 of
      (_::Function fun con field '[BitVecType n1] (BitVecType n1)) -> case f2 of
        (_::Function fun con field '[BitVecType n2] (BitVecType n2))
          -> case compareNat (Proxy::Proxy n1) (Proxy::Proxy n2) of
               GEQ -> GEQ2
               GLT -> GLT2
               GGT -> GGT2
    LT -> GLT2
    GT -> GGT2
  gcompareXX (BVUn _) _ = GLT2
  gcompareXX _ (BVUn _) = GGT2
  gcompareXX f1@Select f2@Select = case f1 of
    (_::Function fun con field (ArrayType idx1 val1 ': idx1) val1) -> case f2 of
      (_::Function fun con field (ArrayType idx2 val2 ': idx2) val2)
        -> case gcompare (getTypes (Proxy::Proxy idx1))
                         (getTypes (Proxy::Proxy idx2)) of
             GEQ -> case gcompare (getType (Proxy::Proxy val1))
                                  (getType (Proxy::Proxy val2)) of
                      GEQ -> GEQ2
                      GLT -> GLT2
                      GGT -> GGT2
             GLT -> GLT2
             GGT -> GGT2
  gcompareXX Select _ = GLT2
  gcompareXX _ Select = GGT2
  gcompareXX f1@Store f2@Store = case f1 of
    (_::Function fun con field (ArrayType idx1 val1 ': val1 ': idx1)
                               (ArrayType idx1 val1)) -> case f2 of
      (_::Function fun con field (ArrayType idx2 val2 ': val2 ': idx2)
                                 (ArrayType idx2 val2))
        -> case gcompare (getTypes (Proxy::Proxy idx1))
                         (getTypes (Proxy::Proxy idx2)) of
             GEQ -> case gcompare (getType (Proxy::Proxy val1))
                                  (getType (Proxy::Proxy val2)) of
                      GEQ -> GEQ2
                      GLT -> GLT2
                      GGT -> GGT2
             GLT -> GLT2
             GGT -> GGT2
  gcompareXX Store _ = GLT2
  gcompareXX _ Store = GGT2
  gcompareXX f1@ConstArray f2@ConstArray = case f1 of
    (_::Function fun con field '[val1] (ArrayType idx1 val1)) -> case f2 of
      (_::Function fun con field '[val2] (ArrayType idx2 val2))
        -> case gcompare (getType (Proxy::Proxy val1))
                         (getType (Proxy::Proxy val2)) of
             GEQ -> case gcompare (getTypes (Proxy::Proxy idx1))
                                  (getTypes (Proxy::Proxy idx2)) of
                      GEQ -> GEQ2
                      GLT -> GLT2
                      GGT -> GGT2
             GLT -> GLT2
             GGT -> GGT2
  gcompareXX ConstArray _ = GLT2
  gcompareXX _ ConstArray = GGT2
  gcompareXX f1@Concat f2@Concat = case f1 of
    (_::Function fun con field '[BitVecType n1,BitVecType n2]
          (BitVecType (n1 + n2))) -> case f2 of
      (_::Function fun con field '[BitVecType m1,BitVecType m2]
            (BitVecType (m1 + m2)))
        -> case compareNat (Proxy::Proxy n1) (Proxy::Proxy m1) of
             GEQ -> case compareNat (Proxy::Proxy n2) (Proxy::Proxy m2) of
               GEQ -> GEQ2
               GLT -> GLT2
               GGT -> GGT2
             GLT -> GLT2
             GGT -> GGT2
  gcompareXX Concat _ = GLT2
  gcompareXX _ Concat = GGT2
  gcompareXX f1@(Extract p1) f2@(Extract p2) = case compareNat p1 p2 of
    GEQ -> case f1 of
      (_::Function fun con field '[BitVecType a1] (BitVecType len1)) -> case f2 of
        (_::Function fun con field '[BitVecType a2] (BitVecType len2))
          -> case compareNat (Proxy::Proxy a1) (Proxy::Proxy a2) of
               GEQ -> case compareNat (Proxy::Proxy len1) (Proxy::Proxy len2) of
                 GEQ -> GEQ2
                 GLT -> GLT2
                 GGT -> GGT2
               GLT -> GLT2
               GGT -> GGT2
    GLT -> GLT2
    GGT -> GGT2
  gcompareXX (Extract _) _ = GLT2
  gcompareXX _ (Extract _) = GGT2
  gcompareXX (Constructor c1) (Constructor c2) = case gcompareXX c1 c2 of
    GEQ2 -> GEQ2
    GLT2 -> GLT2
    GGT2 -> GGT2
  gcompareXX (Constructor _) _ = GLT2
  gcompareXX _ (Constructor _) = GGT2
  gcompareXX (Test c1) (Test c2) = case gcompareXX c1 c2 of
    GEQ2 -> GEQ2
    GLT2 -> GLT2
    GGT2 -> GGT2
  gcompareXX (Test _) _ = GLT2
  gcompareXX _ (Test _) = GGT2
  gcompareXX (Field f1) (Field f2) = case gcompareXX f1 f2 of
    GEQ2 -> GEQ2
    GLT2 -> GLT2
    GGT2 -> GGT2
  gcompareXX (Field _) _ = GLT2
  gcompareXX _ (Field _) = GGT2
  gcompareXX (Divisible n1) (Divisible n2) = case compare n1 n2 of
    EQ -> GEQ2
    LT -> GLT2
    GT -> GGT2

compareNat :: (KnownNat a,KnownNat b) => Proxy a -> Proxy b -> GOrdering a b
compareNat (prA::Proxy a) (prB::Proxy b) = case eqT::Maybe (a :~: b) of
  Just Refl -> GEQ
  Nothing -> case compare (natVal prA) (natVal prB) of
    LT -> GLT
    GT -> GGT

compareSig :: (GetTypes arg1,GetTypes arg2,
               GetType ret1,GetType ret2)
           => Function fun con field arg1 ret1
           -> Function fun con field arg2 ret2
           -> GOrdering2 arg1 arg2 ret1 ret2
compareSig (_::Function fun con field arg1 ret1) (_::Function fun con field arg2 ret2)
  = case eqT :: Maybe (arg1 :~: arg2) of
      Just Refl -> case eqT :: Maybe (ret1 :~: ret2) of
                     Just Refl -> GEQ2
                     Nothing -> case gcompare (getType (Proxy::Proxy ret1))
                                              (getType (Proxy::Proxy ret2)) of
                                  GEQ -> GEQ2
                                  GLT -> GLT2
                                  GGT -> GGT2
      Nothing -> case gcompare (getTypes (Proxy::Proxy arg1))
                               (getTypes (Proxy::Proxy arg2)) of
        GLT -> GLT2
        GGT -> GGT2
