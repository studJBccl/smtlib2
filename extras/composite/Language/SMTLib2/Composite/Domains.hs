module Language.SMTLib2.Composite.Domains where

import Language.SMTLib2 hiding (select,store)
import Language.SMTLib2.Composite.Class
import Language.SMTLib2.Internals.Type.Nat
import Language.SMTLib2.Internals.Type (bvPred,bvSucc,bvAdd,bvSub,bvMul,bvDiv,bvMinValue,bvMaxValue)
import Language.SMTLib2.Internals.Embed
import Data.List (sortBy,sort)
import Data.Ord (comparing)
import Data.Functor.Identity
import Data.GADT.Compare
import Data.Foldable
import Data.Maybe (catMaybes)
import Data.Map (Map)
import qualified Data.Map as Map

class Composite c => IsSingleton c where
  type SingletonType c :: Type
  getSingleton :: (Embed m e,Monad m) => c e -> m (e (SingletonType c))

class IsSingleton c => ToSingleton c where
  toSingleton  :: Embed m e => e (SingletonType c) -> m (c e)

class IsSingleton c => IsConstant c where
  getConstant :: c e -> Maybe (Value (SingletonType c))
  getConstant _ = Nothing

class IsSingleton c => IsRanged c where
  getRange :: (Embed m e,Monad m) => c e -> m (Range (SingletonType c))
  getRange x = do
    x' <- getSingleton x
    tp <- embedTypeOf
    return $ fullRange (tp x')

class (IsSingleton c,Integral (Value (SingletonType c))) => IsNumeric c where
  compositeFromValue :: (Embed m e,Monad m) => Value (SingletonType c) -> m (c e)
  compositePlus :: (Embed m e,Monad m) => c e -> c e -> m (c e)
  compositeMinus :: (Embed m e,Monad m) => c e -> c e -> m (c e)
  compositeSum :: (Embed m e,Monad m) => [c e] -> m (c e)
  compositeSum [] = compositeFromValue (fromInteger 0)
  compositeSum (x:xs) = foldlM compositePlus x xs
  compositeNegate :: (Embed m e,Monad m) => c e -> m (c e)
  compositeNegate x = do
    zero <- compositeFromValue (fromInteger 0)
    compositeMinus zero x
  compositeMult :: (Embed m e,Monad m) => c e -> c e -> m (c e)
  compositeGEQ :: (Embed m e,Monad m) => c e -> c e -> m (e BoolType)
  compositeDiv :: (Embed m e,Monad m) => c e -> c e -> m (c e)
  compositeMod :: (Embed m e,Monad m) => c e -> c e -> m (c e)

class (Composite c,Composite (ElementType c)) => Container c where
  type ElementType c :: (Type -> *) -> *
  elementType :: c Repr -> ElementType c Repr

class (Container arr,Composite idx) => IsArray arr idx where
  newArray :: (Embed m e,Monad m,GetType e) => idx Repr -> ElementType arr e -> m (arr e)
  select :: (Embed m e,Monad m,GetType e,GCompare e) => arr e -> idx e -> m (Maybe (ElementType arr e))
  store :: (Embed m e,Monad m,GetType e,GCompare e) => arr e -> idx e -> ElementType arr e -> m (Maybe (arr e))
  -- | Store an element only if a condition is true
  storeCond :: (Embed m e,Monad m,GetType e,GCompare e) => arr e -> e BoolType -> idx e -> ElementType arr e -> m (Maybe (arr e))
  storeCond arr cond idx el = do
    narr <- store arr idx el
    case narr of
      Nothing -> return Nothing
      Just narr' -> compITE cond narr' arr

data ErrorCondition e
  = NoError
  | SometimesError (e BoolType)
  | AlwaysError

class IsArray arr idx => IsBounded arr idx where
  checkIndex :: (Embed m e,Monad m,GetType e)
             => arr e -> idx e -> m (ErrorCondition e)
  arraySize :: (Embed m e,Monad m) => arr e -> m (idx e)

class (Composite c,IsNumeric idx) => ByteWidth c idx where
  byteWidth :: (Embed m e,Monad m,GetType e) => c e -> m (idx e)

class StaticByteWidth (c :: (Type -> *) -> *) where
  staticByteWidth :: GetType e => c e -> Integer

data ByteRead a e
  = ByteRead { overreads :: Map Integer (a e,e BoolType) -- ^ Maps remaining bytes to incomplete reads
             , readOutside :: Maybe (e BoolType)
             , fullRead :: Maybe (a e)
             , readImprecision :: Maybe (e BoolType) }

data ByteWrite a b e
  = ByteWrite { overwrite :: [(b e,e BoolType)]
              , writeOutside :: Maybe (e BoolType)
              , fullWrite :: Maybe (a e)
              , writeImprecision :: Maybe (e BoolType) }

class (ByteWidth c idx,ByteWidth el idx,StaticByteAccess c el) => ByteAccess c idx el where
  byteRead :: (Embed m e,Monad m,GetType e,GCompare e)
           => c e
           -> idx e
           -> Integer
           -> m (ByteRead el e)
  byteWrite :: (Embed m e,Monad m,GetType e,GCompare e)
            => c e
            -> idx e
            -> el e
            -> m (ByteWrite c el e)

class (Composite c,Composite el) => StaticByteAccess c el where
  staticByteRead :: (Embed m e,Monad m,GetType e,GCompare e)
                 => c e
                 -> Integer
                 -> Integer
                 -> m (ByteRead el e)
  staticByteWrite :: (Embed m e,Monad m)
                  => c e
                  -> Integer
                  -> el e
                  -> m (ByteWrite c el e)

class Composite c => CanConcat c where
  withConcat :: (Embed m e,Monad m) => (c e -> m (a,c e)) -> [c e] -> m (Maybe (a,[c e]))
  withConcat f [c] = do
    (res,nc) <- f c
    return $ Just (res,[nc])
  withConcat _ _ = return Nothing

outsideRead :: e BoolType -> ByteRead a e
outsideRead c = ByteRead Map.empty (Just c) Nothing Nothing

impreciseRead :: e BoolType -> ByteRead a e
impreciseRead c = ByteRead Map.empty Nothing Nothing (Just c)

outsideWrite :: e BoolType -> ByteWrite a b e
outsideWrite c = ByteWrite [] (Just c) Nothing Nothing

fullReadCond :: (Embed m e,Monad m) => ByteRead el e -> m [e BoolType]
fullReadCond r = do
  c1 <- mapM (\(_,c) -> not' c) (Map.elems $ overreads r)
  c2 <- case readOutside r of
    Nothing -> return []
    Just c -> do
      c' <- not' c
      return [c']
  c3 <- case readImprecision r of
    Nothing -> return []
    Just c -> do
      c' <- not' c
      return [c']
  return $ c1++c2++c3

concatRead :: (Embed m e,Monad m,CanConcat el) => el e -> ByteRead el e -> m (ByteRead el e)
concatRead part read = do
  fcond <- true
  let fail = impreciseRead fcond
  novers <- mapM (\(el,cond) -> do
                     nel <- compConcat [part,el]
                     case nel of
                       Nothing -> return Nothing
                       Just nel' -> return $ Just (nel',cond)) (overreads read)
  case sequence novers of
    Nothing -> return fail
    Just novers' -> do
      nfull <- case fullRead read of
        Nothing -> return $ Just Nothing
        Just full -> do
          full' <- compConcat [part,full]
          case full' of
            Nothing -> return Nothing
            Just f -> return $ Just $ Just f
      case nfull of
        Nothing -> return fail
        Just nfull' -> return read { overreads = novers'
                                   , fullRead = nfull' }

compConcat :: (CanConcat c,Embed m e,Monad m) => [c e] -> m (Maybe (c e))
compConcat xs = do
  res <- withConcat (\c -> return (c,c)) xs
  return $ fmap fst res

maybeITE :: (Embed m e,Monad m) => e BoolType -> Maybe (e BoolType) -> Maybe (e BoolType) -> m (Maybe (e BoolType))
maybeITE c Nothing Nothing = return Nothing
maybeITE c (Just r1) Nothing = do
  nr <- c .&. r1
  return $ Just nr
maybeITE c Nothing (Just r2) = do
  nr <- (not' c) .&. r2
  return $ Just nr
maybeITE c (Just r1) (Just r2) = do
  nr <- (c .&. r1) .|. ((not' c) .&. r2)
  return $ Just nr

byteReadITE :: (Embed m e,Monad m,Composite el,GetType e,GCompare e)
            => [(ByteRead el e,e BoolType)] -> m (ByteRead el e)
byteReadITE [] = return $ ByteRead Map.empty Nothing Nothing Nothing
byteReadITE [(r,_)] = return r
byteReadITE ((r,c):rs) = do
  rest <- byteReadITE rs
  notc <- not' c
  over <- merge c notc (overreads r) (overreads rest)
  outside <- maybeITE c (readOutside r) (readOutside rest)
  full <- case fullRead r of
    Nothing -> return $ fullRead rest
    Just full1 -> case fullRead rest of
      Nothing -> return $ Just full1
      Just full2 -> do
        Just nfull <- compITE c full1 full2
        return $ Just nfull
  imprec <- maybeITE c (readImprecision r) (readImprecision rest)
  return $ ByteRead over outside full imprec
  where
    merge :: (Embed m e,Monad m,Composite a,GetType e,GCompare e)
          => e BoolType -> e BoolType
          -> Map Integer (a e,e BoolType)
          -> Map Integer (a e,e BoolType)
          -> m (Map Integer (a e,e BoolType))
    merge c notc x y
      = sequence $ Map.mergeWithKey (\_ (el1,c1) (el2,c2) -> Just $ do
                                        Just nel <- compITE c el1 el2
                                        cond <- c .&. (c1 .|. c2)
                                        return (nel,cond))
        (fmap (\(el,c') -> do
                  nc <- c' .&. c
                  return (el,nc)))
        (fmap (\(el,c') -> do
                  nc <- c' .&. notc
                  return (el,nc))) x y

byteWriteITE :: (Embed m e,Monad m,Composite c,Composite el,GetType e,GCompare e)
             => [(ByteWrite c el e,e BoolType)] -> m (ByteWrite c el e)
byteWriteITE [] = return $ ByteWrite [] Nothing Nothing Nothing
byteWriteITE [(w,_)] = return w
byteWriteITE ((w,c):ws) = do
  rest <- byteWriteITE ws
  notc <- not' c
  over <- merge c notc (overwrite w) (overwrite rest)
  outside <- maybeITE c (writeOutside w) (writeOutside rest)
  full <- case fullWrite w of
    Nothing -> return $ fullWrite rest
    Just full1 -> case fullWrite rest of
      Nothing -> return $ Just full1
      Just full2 -> do
        Just nfull <- compITE c full1 full2
        return $ Just nfull
  imprec <- maybeITE c (writeImprecision w) (writeImprecision rest)
  return $ ByteWrite over outside full imprec
  where
    merge c notc [] ys = mapM (\(rest,cond) -> do
                                  ncond <- notc .&. cond
                                  return (rest,ncond)) ys
    merge c notc xs [] = mapM (\(rest,cond) -> do
                                  ncond <- c .&. cond
                                  return (rest,ncond)) xs
    merge c notc ((xrest,xcond):xs) ((yrest,ycond):ys)
      = case compCompare xrest yrest of
      EQ -> do
        Just nrest <- compITE c xrest yrest
        ncond <- (c .&. xcond) .|. (notc .&. ycond)
        ns <- merge c notc xs ys
        return $ (nrest,ncond):ns
      LT -> do
        ncond <- c .&. xcond
        ns <- merge c notc xs ((yrest,ycond):ys)
        return $ (xrest,ncond):ns
      GT -> do
        ncond <- notc .&. ycond
        ns <- merge c notc ((xrest,ncond):xs) ys
        return $ (yrest,ncond):ns

fromStaticByteRead :: (ByteWidth c idx,StaticByteAccess c el,IsRanged idx,Integral (Value (SingletonType idx)),
                       Embed m e,Monad m,GetType e,GCompare e)
                   => c e
                   -> idx e
                   -> Integer
                   -> m (ByteRead el e)
fromStaticByteRead c (idx :: idx e) sz = do
  rangeStart <- getRange idx
  (objSize :: idx e) <- byteWidth c
  objSizeRange <- getRange objSize
  let objRange = betweenRange (rangedConst 0) objSizeRange
      rangeStart' = intersectionRange objRange rangeStart
      rangeOutside = setMinusRange rangeStart objRange
  case asFiniteRange rangeStart' of
    Just starts -> do
      reads <- sequence
               [ do
                   cond <- getSingleton idx .==. constant start
                   res <- staticByteRead c (toInteger start) sz
                   return (res,cond)
               | start <- starts ]
      read <- byteReadITE reads
      if nullRange rangeOutside
        then return read
        else do
        outside <- compositeGEQ idx objSize
        case readOutside read of
          Nothing -> return $ read { readOutside = Just outside }
          Just outside' -> do
            noutside <- outside .|. outside'
            return $ read { readOutside = Just noutside }
    Nothing -> do
      cond <- true
      return $ ByteRead Map.empty Nothing Nothing (Just cond)

fromStaticByteWrite :: (ByteWidth c idx,StaticByteAccess c el,IsRanged idx,
                        Integral (Value (SingletonType idx)),Embed m e,Monad m,
                        GetType e,GCompare e)
                    => c e
                    -> idx e
                    -> el e
                    -> m (ByteWrite c el e)
fromStaticByteWrite c (idx :: idx e) el = do
  rangeStart <- getRange idx
  (objSize :: idx e) <- byteWidth c
  objSizeRange <- getRange objSize
  let objRange = betweenRange (rangedConst 0) objSizeRange
      rangeStart' = intersectionRange objRange rangeStart
      rangeOutside = setMinusRange rangeStart objRange
  case asFiniteRange rangeStart' of
    Just starts -> do
      nelems <- sequence [ do
                             cond <- getSingleton idx .==. constant start
                             res <- staticByteWrite c (toInteger start) el
                             return (res,cond)
                         | start <- starts ]
      write <- byteWriteITE nelems
      if nullRange rangeOutside
        then return write
        else do
        outside <- compositeGEQ idx objSize
        case writeOutside write of
          Nothing -> return $ write { writeOutside = Just outside }
          Just outside' -> do
            noutside <- outside .|. outside'
            return $ write { writeOutside = Just noutside }
    Nothing -> do
      cond <- true
      return $ ByteWrite [] Nothing Nothing (Just cond)

-- | The boolean states if the range starts included (True) or not (False).
--   Invariant: The range elements are sorted ascending.
type IntRange = (Bool,[Integer])

-- | Describes the allowed values that an expression may have.
--   BoolRange x y describes if value False is allowed (x) and if value True is allowed (y).
data Range tp where
  BoolRange :: Bool -> Bool -> Range BoolType
  IntRange :: IntRange -> Range IntType
  BitVecRange :: Natural bw -> [(Integer,Integer)] -> Range (BitVecType bw)

deriving instance Eq (Range tp)
deriving instance Show (Range tp)

instance Ord (Range tp) where
  compare (BoolRange f1 t1) (BoolRange f2 t2) = compare (f1,t1) (f2,t2)
  compare (IntRange x) (IntRange y) = compare x y
  compare (BitVecRange _ rx) (BitVecRange _ ry) = compare rx ry

instance GetType Range where
  getType (BoolRange _ _) = bool
  getType (IntRange _) = int
  getType (BitVecRange bw _) = bitvec bw

unionRange :: Range tp -> Range tp -> Range tp
unionRange (BoolRange f1 t1) (BoolRange f2 t2) = BoolRange (f1 || f2) (t1 || t2)
unionRange (IntRange x) (IntRange y) = IntRange (unionIntRange x y)
  where
    unionIntRange :: IntRange -> IntRange -> IntRange
    unionIntRange (False,[]) ys = ys
    unionIntRange (True,[]) _ = (True,[])
    unionIntRange xs (False,[]) = xs
    unionIntRange _ (True,[]) = (True,[])
    unionIntRange (False,xs) (False,ys)
      = (False,unionIntRange' xs ys)
    unionIntRange (xi,x:xs) (yi,y:ys)
      = (True,filterRange zs)
      where
        (z,zs)
          | xi && yi = (max x y,unionIntRange' xs ys)
          | xi       = (x,unionIntRange' xs (y:ys))
          | yi       = (y,unionIntRange' (x:xs) ys)
        filterRange [] = [z]
        filterRange (l:u:rest) = if l <= z-1
                                 then if u>z
                                      then u:rest
                                      else filterRange rest
                                 else z:l:u:rest

    unionIntRange' :: [Integer] -> [Integer] -> [Integer]
    unionIntRange' [] ys = ys
    unionIntRange' xs [] = xs
    unionIntRange' (xl:xu:xs) (yl:yu:ys)
      | xu < yl-1 = xl:xu:unionIntRange' xs (yl:yu:ys)
      | yu < xl-1 = yl:yu:unionIntRange' (xl:xu:xs) ys
      | otherwise = unionIntRange' (min xl yl:max xu yu:xs) ys
    unionIntRange' [x] [y] = [min x y]
    unionIntRange' [x] (yl:yu:ys)
      | yu < x-1 = yl:yu:unionIntRange' [x] ys
      | otherwise = [min x yl]
    unionIntRange' (xl:xu:xs) [y]
      | xu < y-1 = xl:xu:unionIntRange' xs [y]
      | otherwise = [min xl y]
unionRange (BitVecRange bw xr) (BitVecRange _ yr)
  = BitVecRange bw (unionRange' xr yr)
  where
    unionRange' [] yr = yr
    unionRange' xr [] = xr
    unionRange' (x@(xlower,xupper):xs) (y@(ylower,yupper):ys)
      | xupper < ylower-1 = x:unionRange' xs (y:ys)
      | yupper < xlower-1 = y:unionRange' (x:xs) ys
      | otherwise = unionRange' ((min xlower ylower,max xupper yupper):xs) ys

intersectionRange :: Range tp -> Range tp -> Range tp
intersectionRange (BoolRange f1 t1) (BoolRange f2 t2)
  = BoolRange (f1 && f2) (t1 && t2)
intersectionRange (IntRange x) (IntRange y) = IntRange (intersectionIntRange x y)
  where
    intersectionIntRange :: IntRange -> IntRange -> IntRange
    intersectionIntRange (True,[]) ys = ys
    intersectionIntRange xs (True,[]) = xs
    intersectionIntRange (True,u1:r1) (True,u2:r2)
      = if u1 > u2
        then (True,u2:intersectionIntRange' (u2:u1:r1) r2)
        else (True,u1:intersectionIntRange' r1 (u1:u2:r2))
    intersectionIntRange (True,u1:r1) (False,l2:r2)
      = if u1 < l2
        then (False,intersectionIntRange' r1 (l2:r2))
        else (False,intersectionIntRange' (l2:u1:r1) (l2:r2))
    intersectionIntRange (False,l1:r1) (True,u2:r2)
      = if u2 < l1
        then (False,intersectionIntRange' (l1:r1) r2)
        else (False,intersectionIntRange' (l1:r1) (l1:u2:r2))
    intersectionIntRange (False,[]) _ = (False,[])
    intersectionIntRange _ (False,[]) = (False,[])
    intersectionIntRange (False,r1) (False,r2)
      = (False,intersectionIntRange' r1 r2)

    intersectionIntRange' [] _ = []
    intersectionIntRange' _ [] = []
    intersectionIntRange' [l1] [l2] = [max l1 l2]
    intersectionIntRange' [l1] (l2:u2:r2)
      = if l1 > u2
        then intersectionIntRange' [l1] r2
        else max l1 l2:u2:r2
    intersectionIntRange' (l1:u1:r1) [l2]
      = if l2 > u1
        then intersectionIntRange' r1 [l2]
        else max l1 l2:u1:r1
    intersectionIntRange' (l1:u1:r1) (l2:u2:r2)
      | u1 < l2   = intersectionIntRange' r1 (l2:u2:r2)
      | u2 < l1   = intersectionIntRange' (l1:u1:r1) r2
      | otherwise = max l1 l2:min u1 u2:case compare u1 u2 of
          LT -> intersectionIntRange' r1 (u1:u2:r2)
          EQ -> intersectionIntRange' r1 r2
          GT -> intersectionIntRange' (u2:u1:r1) r2
intersectionRange (BitVecRange bw x) (BitVecRange _ y)
  = BitVecRange bw (intersectionBV x y)
  where
    intersectionBV [] _ = []
    intersectionBV _ [] = []
    intersectionBV ((l1,u1):r1) ((l2,u2):r2)
      | u1 < l2 = intersectionBV r1 ((l2,u2):r2)
      | u2 < l1 = intersectionBV ((l1,u1):r1) r2
      | otherwise = (max l1 l2,min u1 u2):case compare u1 u2 of
          LT -> intersectionBV r1 ((u1,u2):r2)
          EQ -> intersectionBV r1 r2
          GT -> intersectionBV ((u2,u1):r1) r2

setMinusRange :: Range tp -> Range tp -> Range tp
setMinusRange (BoolRange f1 t1) (BoolRange f2 t2)
  = BoolRange (if f2 then False else f1) (if t2 then False else t1)
setMinusRange (IntRange x) (IntRange y) = IntRange $ minus x y
  where
    minus :: IntRange -> IntRange -> IntRange
    minus (False,[]) _  = (False,[])
    minus _ (True,[])   = (False,[])
    minus xs (False,[]) = xs
    minus (False,xs) (False,ys) = (False,minus' xs ys)
    minus (True,[]) (True,y:ys) = minus (False,[y+1]) (False,ys)
    minus (True,x:xs) (True,y:ys)
      = if x <= y
        then minus (False,xs) (True,y:ys)
        else minus (False,y+1:x:xs) (False,ys)
    minus (False,lx:xs) (True,uy:ys)
      = if uy < lx
        then minus (False,lx:xs) (False,ys)
        else case xs of
               [] -> minus (False,[uy+1]) (False,ys)
               ux:xs' -> if ux <= uy
                         then minus (False,xs') (True,uy:ys)
                         else minus (False,uy+1:ux:xs') (False,ys)
    minus (True,[]) (False,[ly])
      = (True,[ly-1])
    minus (True,[]) (False,ly:uy:ys)
      = minus (True,[ly-1,uy+1]) (False,ys)
    minus (True,ux:xs) (False,[ly])
      = if ly > ux
        then (True,ux:minus' xs [ly])
        else (True,[ly-1])
    minus (True,ux:xs) (False,ly:uy:ys)
      | ly > ux  = (True,ux:minus' xs (ly:uy:ys))
      | uy == ux = minus (True,ly-1:xs) (False,ys)
      | uy < ux  = minus (True,ly-1:uy+1:ux:xs) (False,ys)
      | otherwise = minus (True,ly-1:xs) (False,ux+1:uy:ys)
      
    minus' [] _  = []
    minus' xs [] = xs
    minus' [lx] [ly] = if ly <= lx
                       then []
                       else [lx,ly-1]
    minus' [lx] (ly:uy:ys)
      | uy < lx  = minus' [lx] ys
      | ly <= lx = minus' [uy+1] ys
      | otherwise = lx:ly-1:minus' [uy+1] ys
    minus' (lx:ux:xs) [ly]
      | ly <= lx = []
      | ux < ly = lx:ux:minus' xs [ly]
      | otherwise = [lx,ly-1]
    minus' (lx:ux:xs) (ly:uy:ys)
      | ux < ly = lx:ux:minus' xs (ly:uy:ys)
      | uy < lx = minus' (lx:ux:xs) ys
      | otherwise = let before = if lx < ly
                                 then [lx,ly-1]
                                 else []
                        after = if ux > uy
                                then [uy+1,ux]
                                else []
                        rest = if uy > ux
                               then [ux+1,uy]
                               else []
                    in before++minus' (after++xs) (rest++ys)
setMinusRange (BitVecRange bw r1) (BitVecRange _ r2) = BitVecRange bw (minus r1 r2)
  where
    minus :: [(Integer,Integer)] -> [(Integer,Integer)] -> [(Integer,Integer)]
    minus [] _  = []
    minus xs [] = xs
    minus ((lx,ux):xs) ((ly,uy):ys)
      | ux < ly = (lx,ux):minus xs ((ly,uy):ys)
      | uy < lx = minus ((lx,ux):xs) ys
      | otherwise = let before = if lx < ly
                                 then [(lx,ly-1)]
                                 else []
                        after = if ux > uy
                                then [(uy+1,ux)]
                                else []
                        rest = if uy > ux
                               then [(ux+1,uy)]
                               else []
                    in before++minus (after++xs) (rest++ys)

rangedConst :: Value tp -> Range tp
rangedConst (BoolValue b) = BoolRange (not b) b
rangedConst (IntValue i) = IntRange (False,[i,i])
rangedConst (BitVecValue i bw) = BitVecRange bw [(i,i)]

rangeFromList :: Repr tp -> [Value tp] -> Range tp
rangeFromList BoolRepr xs = foldl (\(BoolRange f t) (BoolValue x)
                                   -> if x then BoolRange f True
                                      else BoolRange True t
                                  ) (BoolRange False False) xs
rangeFromList IntRepr xs = IntRange (False,mkBnds $ sort xs)
  where
    mkBnds :: [Value IntType] -> [Integer]
    mkBnds [] = []
    mkBnds (IntValue x:rest) = buildRange x x rest
    buildRange :: Integer -> Integer -> [Value IntType] -> [Integer]
    buildRange l u [] = [l,u]
    buildRange l u (IntValue y:ys)
      = if y==u || y==u+1
        then buildRange l y ys
        else l:u:buildRange y y ys
rangeFromList (BitVecRepr bw) xs
  = BitVecRange bw (mkBnds $ sort xs)
  where
    mkBnds :: [Value (BitVecType bw)] -> [(Integer,Integer)]
    mkBnds [] = []
    mkBnds (BitVecValue x _:rest) = buildRange x x rest
    buildRange :: Integer -> Integer -> [Value (BitVecType bw)] -> [(Integer,Integer)]
    buildRange l u [] = [(l,u)]
    buildRange l u (BitVecValue y _:ys)
      = if y==u || y==u+1
        then buildRange l y ys
        else (l,u):buildRange y y ys

nullRange :: Range tp -> Bool
nullRange (BoolRange False False) = True
nullRange (IntRange (False,[])) = True
nullRange (BitVecRange _ []) = True
nullRange _ = False

isConst :: Range tp -> Maybe (Value tp)
isConst (BoolRange True False) = Just (BoolValue False)
isConst (BoolRange False True) = Just (BoolValue True)
isConst (IntRange (False,[i,j]))
  | i==j = Just (IntValue i)
isConst (BitVecRange bw [(i,j)])
  | i==j = Just (BitVecValue i bw)
isConst _ = Nothing

rangeInvariant :: Embed m e => Range tp -> e tp -> m (e BoolType)
rangeInvariant (BoolRange True True) _ = true
rangeInvariant (BoolRange False False) _ = false
rangeInvariant (BoolRange True False) e = not' e
rangeInvariant (BoolRange False True) e = pure e
rangeInvariant (IntRange r) e = rangeInvariant' (\isLE c -> if isLE then e .<=. cint c else e .>=. cint c) r
rangeInvariant (BitVecRange bw r) e
  = or' $ fmap (\(lower,upper)
                 -> and' $ (if lower==0
                             then []
                             else [e `bvuge` cbv lower bw])++
                    (if upper==2^bw'-1
                      then []
                      else [e `bvule` cbv upper bw])
               ) r
  where
    bw' = naturalToInteger bw

rangeInvariant' :: Embed m e => (Bool -> Integer -> m (e BoolType)) -- ^ First parameter decides if the operator is <=x (True) or >=x (False).
                -> IntRange
                -> m (e BoolType)
rangeInvariant' f (c,xs) = if c then case xs of
  [] -> true
  x:xs' -> case mk xs' of
    [] -> f True x
    conj -> or' (f True x:conj)
  else case mk xs of
    [] -> false
    [x] -> x
    conj -> or' conj
  where
    mk (l:u:xs) = ((f False l) .&. (f True u)) : mk xs
    mk [l] = [f False l]
    mk [] = []

lowerIntBound :: IntRange -> Maybe (Integer,Bool)
lowerIntBound (incl,x:xs) = Just (x,incl)
lowerIntBound (_,[]) = Nothing

upperIntBound :: IntRange -> Maybe (Integer,Bool)
upperIntBound (_,[]) = Nothing
upperIntBound (incl,xs) = Just $ upper incl xs
  where
    upper incl [i] = (i,not incl)
    upper incl (_:is) = upper (not incl) is

extendLowerIntBound :: IntRange -> IntRange
extendLowerIntBound (False,[]) = (True,[])
extendLowerIntBound (False,_:xs) = (True,xs)
extendLowerIntBound (True,[]) = (True,[])
extendLowerIntBound (True,[_]) = (True,[])
extendLowerIntBound (True,u:l:xs) = (True,xs)

extendUpperIntBound :: IntRange -> IntRange
extendUpperIntBound (False,[]) = (True,[])
extendUpperIntBound (False,[_]) = (True,[])
extendUpperIntBound (incl,xs) = (incl,extend incl xs)
  where
    extend True [u] = []
    extend True [u,l] = []
    extend incl (x:xs) = x:extend (not incl) xs

rangeFixpoint :: Range tp -> Range tp -> Range tp
rangeFixpoint _ (BoolRange f t) = BoolRange f t
rangeFixpoint (IntRange r1) (IntRange r2) = IntRange r3
  where
    r3' = if lowerIntBound r1 == lowerIntBound r2
          then r2
          else extendLowerIntBound r2
    r3 = if upperIntBound r1 == upperIntBound r2
         then r3'
         else extendUpperIntBound r3'
rangeFixpoint (BitVecRange bw []) (BitVecRange _ r2) = BitVecRange bw r2
rangeFixpoint (BitVecRange bw r1) (BitVecRange _ []) = BitVecRange bw r1
rangeFixpoint (BitVecRange bw r1) (BitVecRange _ r2)
  = BitVecRange bw $ fixEnd r1 (fixStart r1 r2)
  where
    fixStart ((l1,u1):r1) ((l2,u2):r2)
      | l1==l2 = (l2,u2):r2
      | otherwise = (0,u2):r2

    fixEnd [(l1,u1)] [(l2,u2)]
      | u1==u2 = [(l2,u2)]
      | otherwise = [(l2,2^(naturalToInteger bw)-1)]
    fixEnd (x:xs) [y] = fixEnd xs [y]
    fixEnd [x] (y:ys) = y:fixEnd [x] ys
    fixEnd (_:xs) (y:ys) = y:fixEnd xs ys

lowerBound :: Range tp -> Maybe (Inf (Value tp))
lowerBound (BoolRange f t)
  | f = Just (Regular (BoolValue False))
  | t = Just (Regular (BoolValue True))
  | otherwise = Nothing
lowerBound (IntRange (True,_)) = Just NegInfinity
lowerBound (IntRange (False,[])) = Nothing
lowerBound (IntRange (False,l:_)) = Just (Regular (IntValue l))
lowerBound (BitVecRange _ []) = Nothing
lowerBound (BitVecRange bw ((l,_):_)) = Just (Regular (BitVecValue l bw))

upperBound :: Range tp -> Maybe (Inf (Value tp))
upperBound (BoolRange f t)
  | t = Just (Regular (BoolValue True))
  | f = Just (Regular (BoolValue False))
  | otherwise = Nothing
upperBound (IntRange (False,[])) = Nothing
upperBound (IntRange (True,[])) = Just PosInfinity
upperBound (IntRange (incl,rng)) = upper incl rng
  where
    upper False [l] = Just PosInfinity
    upper True [u] = Just (Regular (IntValue u))
    upper incl (_:xs) = upper (not incl) xs
upperBound (BitVecRange _ []) = Nothing
upperBound (BitVecRange bw xs) = Just (Regular (BitVecValue (snd $ last xs) bw))

intRangeIncludes :: Integer -> IntRange -> Bool
intRangeIncludes _ (incl,[]) = incl
intRangeIncludes n (False,l:xs)
  | n < l = False
  | otherwise = intRangeIncludes n (True,xs)
intRangeIncludes n (True,u:xs)
  | n <= u = True
  | otherwise = intRangeIncludes n (False,xs)

includes :: Value tp -> Range tp -> Bool
includes (BoolValue v) (BoolRange f t) = if v then t else f
includes (IntValue v) (IntRange r) = intRangeIncludes v r
includes (BitVecValue v _) (BitVecRange _ r)
  = includes' r
  where
    includes' [] = False
    includes' ((l,u):rest) = (v >= l && v <= u) || includes' rest

fullRange :: Repr tp -> Range tp
fullRange BoolRepr        = BoolRange True True
fullRange IntRepr         = IntRange (True,[])
fullRange (BitVecRepr bw) = BitVecRange bw [(0,2^(naturalToInteger bw)-1)]

emptyRange :: Repr tp -> Range tp
emptyRange BoolRepr        = BoolRange False False
emptyRange IntRepr         = IntRange (False,[])
emptyRange (BitVecRepr bw) = BitVecRange bw []

isEmptyRange :: Range tp -> Bool
isEmptyRange (BoolRange False False) = True
isEmptyRange (IntRange (False,[])) = True
isEmptyRange (BitVecRange _ []) = True
isEmptyRange _ = False

singletonRange :: Value tp -> Range tp
singletonRange (BoolValue b) = BoolRange (not b) b
singletonRange (IntValue v) = IntRange (False,[v,v])
singletonRange (BitVecValue v bw) = BitVecRange bw [(v,v)]

leqRange :: Integer -> Range IntType
leqRange x = IntRange (True,[x])

ltRange :: Integer -> Range IntType
ltRange x = IntRange (True,[x-1])

geqRange :: Integer -> Range IntType
geqRange x = IntRange (False,[x])

gtRange :: Integer -> Range IntType
gtRange x = IntRange (False,[x+1])

intersectionIntRange :: IntRange -> IntRange -> IntRange
intersectionIntRange (False,[]) _ = (False,[])
intersectionIntRange _ (False,[]) = (False,[])
intersectionIntRange (True,[]) ys = ys
intersectionIntRange xs (True,[]) = xs
intersectionIntRange (False,xs) (False,ys)
  = (False,intersectionIntRange' xs ys)
--intersectionIntRange (True,x:xs) (True,y:ys) = case compare x y of
--  EQ -> (True,x:intersectionIntRange' 

intersectionIntRange' :: [Integer] -> [Integer] -> [Integer]
intersectionIntRange' [] _ = []
intersectionIntRange' _ [] = []
intersectionIntRange' (xl:xu:xs) (yl:yu:ys)
  | xu < yl-1 = intersectionIntRange' xs (yl:yu:ys)
  | yu < xl-1 = intersectionIntRange' (xl:xu:xs) ys
  | otherwise = max xl yl:min xu yu:
                case compare xu yu of
                  EQ -> intersectionIntRange' xs ys
                  LT -> intersectionIntRange' xs (xu:yu:ys)
                  GT -> intersectionIntRange' (yu:xu:xs) ys

rangeType :: Range tp -> Repr tp
rangeType (BoolRange _ _) = bool
rangeType (IntRange _) = int
rangeType (BitVecRange bw _) = bitvec bw

asFiniteRange :: Range tp -> Maybe [Value tp]
asFiniteRange (BoolRange f t)
  = Just $ (if f then [BoolValue False] else [])++
    (if t then [BoolValue True] else [])
asFiniteRange (IntRange (True,_)) = Nothing
asFiniteRange (IntRange (False,xs))
  = asFinite xs
  where
    asFinite [] = Just []
    asFinite [_] = Nothing
    asFinite (l:u:xs) = do
      xs' <- asFinite xs
      return $ [IntValue x | x <- [l..u]]++xs'
asFiniteRange (BitVecRange bw rng)
  = Just $ [ BitVecValue x bw
           | (l,u) <- rng
           , x <- [l..u] ]

-- To support easier manipulation of ranges, we introduce the Bounds type:

--type Bounds = Maybe (Maybe Integer,[(Integer,Integer)],Maybe Integer)

data Inf x = NegInfinity | Regular x | PosInfinity deriving (Eq,Ord,Show,Functor)

type Bounds x = [(Inf x,Inf x)]

addInf :: (a -> a -> a) -> Inf a -> Inf a -> Maybe (Inf a)
addInf add (Regular x) (Regular y) = Just $ Regular $ x `add` y
addInf _ NegInfinity PosInfinity = Nothing
addInf _ PosInfinity NegInfinity = Nothing
addInf _ PosInfinity _ = Just PosInfinity
addInf _ NegInfinity _ = Just NegInfinity
addInf _ _ PosInfinity = Just PosInfinity
addInf _ _ NegInfinity = Just NegInfinity

addInf' :: (a -> a -> a) -> Inf a -> Inf a -> Inf a
addInf' add x y = case addInf add x y of
  Just r -> r
  Nothing -> error "Adding positive and negative infinity undefined."

subInf :: (a -> a -> a) -> Inf a -> Inf a -> Maybe (Inf a)
subInf sub (Regular x) (Regular y) = Just $ Regular $ x `sub` y
subInf _ NegInfinity NegInfinity = Nothing
subInf _ PosInfinity PosInfinity = Nothing
subInf _ PosInfinity _ = Just PosInfinity
subInf _ NegInfinity _ = Just NegInfinity
subInf _ _ PosInfinity = Just NegInfinity
subInf _ _ NegInfinity = Just PosInfinity

subInf' :: (a -> a -> a) -> Inf a -> Inf a -> Inf a
subInf' add x y = case subInf add x y of
  Just r -> r
  Nothing -> error "Subtracting infinity undefined."

mulInf :: Ord a => a -- ^ Zero
       -> (a -> a -> a) -- ^ Multiplication
       -> Inf a -> Inf a -> Inf a
mulInf _ mul (Regular x) (Regular y) = Regular $ x `mul` y
mulInf zero _ (Regular x) PosInfinity = case compare x zero of
  LT -> NegInfinity
  EQ -> Regular zero
  GT -> PosInfinity
mulInf zero _ (Regular x) NegInfinity = case compare x zero of
  LT -> PosInfinity
  EQ -> Regular zero
  GT -> NegInfinity
mulInf _ _ PosInfinity PosInfinity = PosInfinity
mulInf _ _ PosInfinity NegInfinity = NegInfinity
mulInf zero _ PosInfinity (Regular y) = case compare y zero of
  LT -> NegInfinity
  EQ -> Regular zero
  GT -> PosInfinity
mulInf _ _ NegInfinity PosInfinity = NegInfinity
mulInf _ _ NegInfinity NegInfinity = PosInfinity
mulInf zero _ NegInfinity (Regular y) = case compare y zero of
  LT -> PosInfinity
  EQ -> Regular zero
  GT -> NegInfinity

instance (Ord x,Num x) => Num (Inf x) where
  fromInteger = Regular . fromInteger
  (+) = addInf' (+)
  (-) = subInf' (-)
  (*) = mulInf 0 (*)
  negate (Regular x) = Regular $ negate x
  negate NegInfinity = PosInfinity
  negate PosInfinity = NegInfinity
  abs (Regular x) = Regular $ abs x
  abs _ = PosInfinity
  signum (Regular x) = Regular $ signum x
  signum PosInfinity = 1
  signum NegInfinity = -1

instance Real x => Real (Inf x) where
  toRational NegInfinity = error "toRational.{Inf x}: called on negative infinity"
  toRational (Regular x) = toRational x
  toRational PosInfinity = error "toRational.{Inf x}: called on positive infinity"

instance Enum x => Enum (Inf x) where
  succ NegInfinity = NegInfinity
  succ (Regular x) = Regular (succ x)
  succ PosInfinity = PosInfinity
  pred NegInfinity = NegInfinity
  pred (Regular x) = Regular (pred x)
  pred PosInfinity = PosInfinity
  toEnum x = Regular (toEnum x)
  fromEnum NegInfinity = error "fromEnum.{Inf x}: called on negative infinity"
  fromEnum (Regular x) = fromEnum x
  fromEnum PosInfinity = error "fromEnum.{Inf x}: called on positive infinity"

{-instance Integral x => Integral (Inf x) where
  quot NegInfinity (Regular y) = case compare y 0 of
    LT -> PosInfinity
    EQ -> error "quot{Inf}: divide by zero"
    GT -> NegInfinity
  quot PosInfinity (Regular y) = case compare y 0 of
    LT -> NegInfinity
    EQ -> error "quot{Inf}: divide by zero"
    GT -> PosInfinity
  quot (Regular x) (Regular y) = Regular (x `quot` y)
  quot (Regular _) PosInfinity = Regular 0
  quot (Regular _) NegInfinity = Regular 0
  quot _ _ = error "quot{Inf}: two infinite arguments"
  rem (Regular x) (Regular y) = Regular (x `rem` y)
  rem PosInfinity _ = error "rem{Inf}: first argument cannot be infinite."
  rem NegInfinity _ = error "rem{Inf}: first argument cannot be infinite."
  rem (Regular x) PosInfinity = Regular x
  rem (Regular x) NegInfinity = Regular x
  div (Regular x) (Regular y) = Regular (x `div` y)
  div PosInfinity (Regular x) = case compare x 0 of
    LT -> NegInfinity
    EQ -> error "div{Inf}: divide by zero"
    GT -> PosInfinity
  div NegInfinity (Regular x) = case compare x 0 of
    LT -> PosInfinity
    EQ -> error "div{Inf}: divide by zero"
    GT -> NegInfinity
  div (Regular x) PosInfinity = if x>=0
                                then Regular 0
                                else Regular (-1)
  div (Regular x) NegInfinity = if x>0
                                then Regular (-1)
                                else Regular 0
  div _ _ = error "div{Inf}: two infinite arguments"
  mod (Regular x) (Regular y) = Regular (x `mod` y)
  mod (Regular x) PosInfinity = if x>=0
                                then Regular x
                                else error "mod{Inf}: undefined for negative first parameter and positive infinity second parameter"
  mod (Regular x) NegInfinity = if x<=0
                                then Regular x
                                else error "mod{Inf}: undefined for positive first parameter and negative infinity second parameter"
  mod _ _ = error "mod{Inf}: undefined"-}

toBounds :: Range tp -> Bounds (Value tp)
toBounds (BoolRange True True) = [(Regular $ BoolValue False,Regular $ BoolValue True)]
toBounds (BoolRange f t) = (if f then [(Regular $ BoolValue False,Regular $ BoolValue False)] else [])++
                           (if t then [(Regular $ BoolValue True,Regular $ BoolValue True)] else [])
toBounds (IntRange r) = case r of
  (True,[]) -> [(NegInfinity,PosInfinity)]
  (True,x:xs) -> (NegInfinity,Regular $ IntValue x):toBounds' xs
  (False,xs) -> toBounds' xs
  where
    toBounds' :: [Integer] -> Bounds (Value IntType)
    toBounds' [] = []
    toBounds' [lower] = [(Regular $ IntValue lower,PosInfinity)]
    toBounds' (lower:upper:xs) = (Regular $ IntValue lower,Regular $ IntValue upper):toBounds' xs
toBounds (BitVecRange bw rng) = [(Regular $ BitVecValue lower bw,
                                  Regular $ BitVecValue upper bw)
                                | (lower,upper) <- rng]

fromBounds :: Repr tp -> Bounds (Value tp) -> Range tp
fromBounds tp bnd = case tp of
  BoolRepr -> boolRange False bnd''
  IntRepr -> intRange bnd''
  BitVecRepr bw -> bvRange bw bnd''
  where
    bnd' = sortBy (comparing fst) bnd
    bnd'' = mergeBounds prev bnd
    prev = case tp of
      BoolRepr -> pred
      IntRepr -> pred
      RealRepr -> id
      BitVecRepr _ -> bvPred
    mergeBounds :: Ord a => (a -> a) -> Bounds a -> Bounds a
    mergeBounds _ [] = []
    mergeBounds _ [x] = [x]
    mergeBounds f ((NegInfinity,NegInfinity):xs) = mergeBounds f xs
    mergeBounds f ((PosInfinity,PosInfinity):xs) = mergeBounds f xs
    mergeBounds f ((l1,u1):(l2,u2):xs)
      | l1 > u1       = mergeBounds f ((l2,u2):xs)
      | l2 > u2       = mergeBounds f ((l1,u1):xs)
      | u1>=fmap f l2 = mergeBounds f ((l1,max u1 u2):xs)
      | otherwise     = (l1,u1):mergeBounds f ((l2,u2):xs)
    boolRange :: Bool -> Bounds (Value BoolType) -> Range BoolType
    boolRange hasF [] = BoolRange hasF False
    boolRange _ ((NegInfinity,PosInfinity):_) = BoolRange True True
    boolRange _ ((NegInfinity,Regular (BoolValue x)):xs)
      = if x
        then BoolRange True True
        else boolRange True xs
    boolRange hasF ((Regular (BoolValue x),PosInfinity):xs)
      = BoolRange (hasF && not x) True
    boolRange hasF ((Regular (BoolValue l),Regular (BoolValue u)):xs)
      = if u
        then BoolRange (hasF || not l) True
        else boolRange True xs
             
    intRange :: Bounds (Value IntType) -> Range IntType
    intRange [] = IntRange (False,[])
    intRange [(NegInfinity,PosInfinity)] = IntRange (True,[])
    intRange ((NegInfinity,Regular (IntValue x)):xs) = IntRange (True,x:intRange' xs)
    intRange xs = IntRange (False,intRange' xs)

    intRange' :: Bounds (Value IntType) -> [Integer]
    intRange' [] = []
    intRange' [(Regular (IntValue x),PosInfinity)] = [x]
    intRange' ((Regular (IntValue l),Regular (IntValue u)):xs) = l:u:intRange' xs

    bvRange :: Natural bw -> Bounds (Value (BitVecType bw)) -> Range (BitVecType bw)
    bvRange bw xs = BitVecRange bw (bvRange' (naturalToInteger bw) xs)

    bvRange' :: Integer -> Bounds (Value (BitVecType bw)) -> [(Integer,Integer)]
    bvRange' _ [] = []
    bvRange' bw ((NegInfinity,PosInfinity):_) = [(0,2^bw-1)]
    bvRange' bw ((NegInfinity,Regular (BitVecValue u _)):xs)
      | u >= 0 = (0,u):bvRange' bw xs
      | otherwise = bvRange' bw xs
    bvRange' bw ((Regular (BitVecValue l _),PosInfinity):_)
      | l < 2^bw = [(l,2^bw-1)]
      | otherwise = []
    bvRange' bw ((Regular (BitVecValue l _),Regular (BitVecValue u _)):xs)
      | u < 0 || l >= 2^bw = bvRange' bw xs
      | otherwise          = (max l 0,min u (2^bw-1)):bvRange' bw xs

addOverflow :: Ord a => a -- ^ Zero
            -> (a -> a -> a) -- ^ Addition
            -> a -> a -> (a,Bool)
addOverflow zero add x y = (sum,overf)
  where
    sum = x `add` y
    overf = if x >= zero
            then sum < y
            else sum > y

multOverflow :: Eq a => (a -> a -> a) -> (a -> a -> a) -> a -> a -> (a,Bool)
multOverflow mul div x y = (prod,prod `div` y /= x)
  where
    prod = x `mul` y

addBounds :: Ord a => a -> (a -> a -> a) -> Maybe a -> Bounds a -> Bounds a -> Bounds a
addBounds zero add lim b1 b2 = [ r
                               | r1 <- b1
                               , r2 <- b2
                               , r <- addRange zero (addInf' add) lim r1 r2 ]

subBounds :: Ord a => a -> (a -> a -> a) -> Maybe a -> Bounds a -> Bounds a -> Bounds a
subBounds zero add lim b1 b2 = [ r
                               | r1 <- b1
                               , r2 <- b2
                               , r <- addRange zero (subInf' add) lim r1 r2 ]

addRange :: Ord a => a -- ^ Zero
         -> (Inf a -> Inf a -> Inf a) -- ^ Addition
         -> Maybe a -- ^ Upper bound
         -> (Inf a,Inf a)
         -> (Inf a,Inf a)
         -> [(Inf a,Inf a)]
addRange zero add (Just lim) (l1,u1) (l2,u2)
  | overfL = [(nl,nu)]
  | overfU = if nl <= nu
             then [(Regular zero,Regular lim)]
             else [(Regular zero,nu),(nl,Regular lim)]
  | otherwise = [(nl,nu)]
  where
    (nl,overfL) = addOverflow (Regular zero) add l1 l2
    (nu,overfU) = addOverflow (Regular zero) add u1 u2
addRange _ add Nothing (l1,u1) (l2,u2)
  = [(add l1 l2,add u1 u2)]

multBounds :: Ord a => a -> (a -> a -> a) -> (a -> a -> a) -> Maybe a -> Bounds a -> Bounds a -> Bounds a
multBounds zero mul div lim b1 b2 = [ r | r1 <- b1
                                        , r2 <- b2
                                        , r <- multRange zero mul div lim r1 r2 ]
  where
    multRange :: Ord a => a -> (a -> a -> a) -> (a -> a -> a) -> Maybe a -> (Inf a,Inf a) -> (Inf a,Inf a) -> [(Inf a,Inf a)]
    multRange zero mul div (Just lim) (Regular l1,Regular u1) (Regular l2,Regular u2)
      | overfL || overfU = [(Regular zero,Regular lim)]
      | otherwise = [(Regular nl,Regular nu)]
      where
        (nl,overfL) = multOverflow mul div l1 l2
        (nu,overfU) = multOverflow mul div u1 u2
    multRange zero mul _ Nothing (l1,u1) (l2,u2) = [(mulInf zero mul l1 l2,mulInf zero mul u1 u2)]

negBounds :: (Num a,Ord a) => Bounds a -> Bounds a
negBounds = reverse . fmap neg
  where
    neg (l,u) = (negate u,negate l)

absBounds :: (Num a,Ord a) => Bounds a -> Bounds a
absBounds = fmap abs'
  where
    abs' (l,u)
      | l >= 0    = (l,u)
      | u >= 0    = (0,u)
      | otherwise = (abs u,abs l)

signumBounds :: (Num a,Ord a) => Bounds a -> Bounds a
signumBounds = sign False False False
  where
    sign True True True _     = [(-1,1)]
    sign True True False []   = [(-1,0)]
    sign True False True []   = [(-1,-1),(1,1)]
    sign True False False []  = [(-1,-1)]
    sign False True True []   = [(0,1)]
    sign False True False []  = [(0,0)]
    sign False False True []  = [(1,1)]
    sign False False False [] = []
    sign hasN hasZ hasP ((l,u):xs)
      = case compare l 0 of
          LT -> case compare u 0 of
            LT -> sign True hasZ hasP xs
            EQ -> sign True True hasP xs
            GT -> sign True True True xs
          EQ -> case compare u 0 of
            EQ -> sign hasN True hasP xs
            GT -> sign hasN True True xs
          GT -> sign hasN hasZ True xs

instance Num (Range IntType) where
  (+) r1 r2 = fromBounds int $ addBounds 0 (+) Nothing (toBounds r1) (toBounds r2)
  (-) r1 r2 = fromBounds int $ subBounds 0 (-) Nothing (toBounds r1) (toBounds r2)
  (*) r1 r2 = fromBounds int $ multBounds 0 (*) div Nothing (toBounds r1) (toBounds r2)
  negate r = fromBounds int $ negBounds (toBounds r)
  abs r = fromBounds int $ absBounds (toBounds r)
  signum r = fromBounds int $ signumBounds (toBounds r)
  fromInteger x = IntRange (False,[x,x])

instance IsNatural bw => Num (Range (BitVecType bw)) where
  (+) r1@(BitVecRange bw _) r2 = fromBounds (bitvec bw) $ addBounds (BitVecValue 0 bw) bvAdd (Just maxBound) (toBounds r1) (toBounds r2)
  (-) r1@(BitVecRange bw _) r2 = fromBounds (bitvec bw) $ subBounds (BitVecValue 0 bw) bvSub (Just maxBound) (toBounds r1) (toBounds r2)
  (*) r1@(BitVecRange bw _) r2 = fromBounds (bitvec bw) $ multBounds (BitVecValue 0 bw) bvMul bvDiv (Just maxBound) (toBounds r1) (toBounds r2)
  negate r@(BitVecRange bw _) = fromBounds (bitvec bw) $ negBounds (toBounds r)
  abs r@(BitVecRange bw _) = fromBounds (bitvec bw) $ absBounds (toBounds r)
  signum r@(BitVecRange bw _) = fromBounds (bitvec bw) $ signumBounds (toBounds r)
  fromInteger x = BitVecRange getNatural [(x,x)]

betweenBounds :: Ord a => Bounds a -> Bounds a -> Bounds a
betweenBounds b1 b2 = [ (min l1 l2,max u1 u2)
                      | (l1,u1) <- b1, (l2,u2) <- b2 ]

betweenRange :: Range tp -> Range tp -> Range tp
betweenRange r1 r2 = fromBounds (rangeType r1) $ betweenBounds (toBounds r1) (toBounds r2)

rangeFromTo :: Value tp -> Value tp -> Range tp
rangeFromTo from to = fromBounds (getType from) [(Regular from,Regular to)]

rangeFrom :: Value tp -> Range tp
rangeFrom from = fromBounds (getType from) [(Regular from,PosInfinity)]

rangeTo :: Value tp -> Range tp
rangeTo to = fromBounds (getType to) [(NegInfinity,Regular to)]

rangeAdd :: Range tp -> Range tp -> Range tp
rangeAdd r1@(IntRange {}) r2 = fromBounds int $ addBounds 0 (+) Nothing (toBounds r1) (toBounds r2)
rangeAdd r1@(BitVecRange bw _) r2 = fromBounds (bitvec bw) $ addBounds (BitVecValue 0 bw) bvAdd (Just $ bvMaxValue False (BitVecRepr bw)) (toBounds r1) (toBounds r2)

rangeMult :: Range tp -> Range tp -> Range tp
rangeMult r1@(IntRange {}) r2 = fromBounds int $ multBounds 0 (*) div Nothing (toBounds r1) (toBounds r2)
rangeMult r1@(BitVecRange bw _) r2 = fromBounds (bitvec bw) $ multBounds (BitVecValue 0 bw) bvMul bvDiv (Just $ bvMaxValue False (BitVecRepr bw)) (toBounds r1) (toBounds r2)