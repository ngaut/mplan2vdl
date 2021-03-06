module Config ( Config(..)
              , ColInfo(..)
              , checkColInfo
              , makeConfig
              , isPkey
              , isFKRef
              , lookupPkey
              , isPartialFk
              , isPartialPk
              , AggStrategy(..)
              , OutputFormat(..)
              , FKCols
              , PKCols
              , BoundsRec
              , StorageRec
              , DictRec
              , FKJoinOrder(..)
              , FKInstance(..)
              ) where

import Types
import Name as NameTable
import SchemaParser(Table(..),Key(..))

import Data.Foldable
import Data.Data
import qualified Data.Vector as V
import Control.DeepSeq(NFData)
import GHC.Generics
import Control.Exception.Base
import qualified Data.Map.Strict as Map
import Data.List.NonEmpty(NonEmpty(..))
import qualified Data.List.NonEmpty as N
import qualified Data.ByteString.Lazy as B
import Data.Hashable
import qualified Data.ByteString.Lazy.Char8 as C
import qualified Data.HashMap.Strict as HashMap

type HashMap = HashMap.HashMap
type Map = Map.Map

data OutputFormat = VdlFormat | VliteFormat deriving (Eq,Show,Data)
--type Set = Set.Set


-- we use integer in the rec so that strings get
-- parsed to Integer.
-- Parsing a string as an Int8, for example,  can silently
-- wraps the around the input string value and return an Int8
-- which is not the behavior we want here.
-- The same thing happens with wider types.
-- We want any type bound errors (such as being <  0 when it shouldnt) to
-- be the result of errors inherent in the input data, not of
-- errors due to overflwoing numbers within the program.


type BoundsRec = (B.ByteString, B.ByteString, Integer, Integer, Integer, Integer)

-- contents of select * from storage
type StorageRec = ( C.ByteString -- schema
                  , C.ByteString -- table
                  , C.ByteString -- column
                  , C.ByteString -- type
                  , C.ByteString -- location
                  , Integer -- count
                  , Integer -- typewidth (bytes)
                  , Integer -- columnsize (bytes)
                  , Integer -- heapsize
                  , Integer -- hashes
                  , Integer -- imprints
                  , C.ByteString  -- sorted (boolean)
                  )


type DictRec = ( C.ByteString -- schema
               , C.ByteString -- table
               , C.ByteString -- column
               , Integer -- encoding
               )



makeDictionary :: V.Vector DictRec -> (HashMap C.ByteString Integer)
makeDictionary vec =
  let merge mp (_,_,str,i) = HashMap.insert str i mp
  in V.foldl' merge HashMap.empty vec


toKeyPair :: (NameTable TypeSpec) -> StorageRec -> [ (Name, StorageInfo) ]
toKeyPair ns (_,tab,col,typstring,_,colcount,bytewidth,colsize,_,_,_,_) =
      do let name = Name [tab,col]
         tspec <- if typstring /= "oid"
                  then
                    case NameTable.lookup name ns of
                      Left _ -> []
                      Right  (_,b) -> [b]
                  else [TypeSpec { tname="oid", tparams=[] }]
         let mtype = resolveTypeSpec tspec
         let storagesize = colsize `quot` colcount
         let off = colsize `rem` colcount
         let matches = (case mtype of
                           MChar _ -> True
                           MVarchar _ -> True
                           _ -> storagesize == bytewidth )
         return $ assert (matches &&  (off == 0))  (name, StorageInfo{mtype,storagesize})

-- holds the names of the matching columns for an fk.
-- the order matters, watch out. left is fact, right is dim.
type FKCols = NonEmpty (Name, Name)
type PKCols = NonEmpty Name

-- we use Integer values here so that our metadata calculations
-- don't overflow.
data ColInfo = ColInfo
  { bounds::(Integer,Integer)
  , trailing_zeros::Integer -- largest power of two known to divide all values in column
  , count::Integer
  , stype::SType
  , dtype::(DType,C.ByteString)
  } deriving (Eq,Show,Generic)

instance Hashable ColInfo

data StorageInfo = StorageInfo
  { mtype :: MType
  , storagesize :: Integer
  }

instance NFData ColInfo

checkColInfo :: ColInfo -> ColInfo
checkColInfo i@(ColInfo {bounds=(l,u), count, stype, trailing_zeros}) =
  if l <= u && count > 0 && withinBounds (l,u) stype && trailing_zeros >=0
  then i
  else i -- error $ "info does not pass validation: " ++ show i ++ "\ntype bounds: " ++ (show $  boundsOf stype)

addEntry :: [Name] -> NameTable StorageInfo -> NameTable ColInfo -> BoundsRec -> NameTable ColInfo
addEntry constraints storagetab nametab (tab,col,colmin,colmax,colcount,trailing_zeros) =
  let StorageInfo {mtype}  = snd $ NameTable.lookup_err (Name [tab,col]) storagetab
      name = Name [tab,col]
      stype = getSTypeOfMType mtype
      dtype = (getDTypeOfMType  mtype name,"from storage file")
      colinfo = checkColInfo $ ColInfo { bounds=(colmin, colmax), count=colcount, stype, trailing_zeros, dtype }
      plain = NameTable.insert name colinfo nametab
  in if elem (Name[tab,col]) constraints
     then NameTable.insert (Name [tab, B.append "%" col]) colinfo plain -- constraints get marked with % as well
     else plain

makeConfig :: Bool -> OutputFormat -> Double -> Bool -> Integer -> AggStrategy -> V.Vector BoundsRec -> (V.Vector StorageRec) -> [Table] -> V.Vector DictRec -> Config
makeConfig cross_product output_format sparsity_threshold metadata gboffset aggregation_strategy boundslist storagelist tables dictlist =
  let format = output_format
      show_metadata = metadata
      dictionary = makeDictionary dictlist
      constraints = foldMap getTableConstraints tables
      tspecs = NameTable.fromList $ foldMap getTspecs tables
      storagemap = NameTable.fromList $ foldMap (toKeyPair tspecs)  (V.toList storagelist)
      colinfo =  foldl' (addEntry constraints storagemap) NameTable.empty boundslist
      allrefs = foldMap makeFKEntries tables
      straighten qual (a,b) = case qual of
        FactDim -> (a,b)
        DimFact -> (b,a)
      make_partials (FKInstance {cols=nelist, fkjoinorder=qual}) = N.toList $ N.map (\n -> (n, (qual,N.map (straighten qual) nelist))) nelist
      partialfks = Map.fromList $ foldMap make_partials allrefs
      allpkeys = map makePKeys tables -- sort the non-empty lists
      partialpks = Map.fromList $
           foldMap (\(pkl,_) -> map (\col -> (col,pkl)) (N.toList pkl)) allpkeys
      pktable = map pkpair tables
      fkpairs = zip (map cols allrefs) (allrefs)
  in Config { cross_product, format, sparsity_threshold, show_metadata, gboffset, aggregation_strategy, dictionary, colinfo, fkrefs=Map.fromList fkpairs, pkeys=Map.fromList allpkeys,
              tablePKeys=Map.fromList pktable, partialfks, partialpks }

pkpair :: Table -> (Name,Name)
pkpair Table{name, pkey=PKey{pkconstraint}} = (name, concatName name pkconstraint)
pkpair _ = error "table with no pkey"

concatName :: Name -> Name -> Name
concatName (Name a) (Name b) = Name (a ++ b)

getTableConstraints :: Table -> [Name]
getTableConstraints Table {name, pkey, fkeys}
  = map (concatName name) (getConstraint pkey : map getConstraint fkeys)

getTspecs :: Table -> [(Name, TypeSpec)]
getTspecs tab = map (\(n,ts) -> (concatName (name tab) n, ts)) $ N.toList $ columns tab

getConstraint :: Key -> Name
getConstraint PKey {pkconstraint} = pkconstraint
getConstraint FKey {fkconstraint} = fkconstraint

makePKeys :: Table -> (NonEmpty Name, Name)
makePKeys Table { pkey=FKey {} }  = error "fkey in place of pkey"
makePKeys Table { name, pkey=PKey { pkcols, pkconstraint } } = (N.sort (N.map (concatName name) pkcols), concatName name pkconstraint)

data FKJoinOrder = FactDim | DimFact deriving (Show,Eq,Generic,Ord)
instance Hashable FKJoinOrder

-- holds an instance of an fk and meta information about it
data FKInstance = FKInstance { cols::FKCols, fkjoinorder::FKJoinOrder, fact::Name, dim::Name, idxname::Name } deriving (Eq, Show)

makeFKEntries :: Table -> [FKInstance]
makeFKEntries Table { name, fkeys } =
  do FKey { references, colmap, fkconstraint } <- fkeys
     let (local,remote) = N.unzip colmap
     let localcols = fmap (concatName name) local
     let remotecols = fmap (concatName references) remote
     let joinidx = concatName name fkconstraint
     let implicit = N.sort (N.zip localcols remotecols) -- sort for canonical order
     let implicit_back = N.sort (N.zip remotecols localcols)
     let tidname = concatName references (Name ["%TID%"])
     let explicit = ( joinidx
                    , tidname ) :|[]
     let explicit_back = (tidname, joinidx) :| []
     let fkrefs = [ FKInstance {cols=implicit, fkjoinorder=FactDim, fact=name, dim=references, idxname=joinidx}
                  , FKInstance {cols=implicit_back, fkjoinorder=DimFact, fact=name, dim=references, idxname=joinidx}
                  , FKInstance {cols=explicit, fkjoinorder=FactDim, fact=name, dim=references, idxname=joinidx}
                  , FKInstance {cols=explicit_back, fkjoinorder=DimFact, fact=name, dim=references, idxname=joinidx}
                  ]
     fkrefs


data AggStrategy = AggHierarchical Integer | AggSerial | AggShuffle deriving (Show, Eq, Data, Typeable)

data Config =  Config  { cross_product :: Bool
                       , sparsity_threshold :: Double
                       , aggregation_strategy :: AggStrategy
                       , show_metadata :: Bool
                       , gboffset :: Integer
                       , format :: OutputFormat
                       , dictionary :: HashMap C.ByteString Integer
                       , colinfo :: NameTable ColInfo
                       , fkrefs :: Map FKCols FKInstance
                                   -- shows the fact -> dimension direction of the dependence
                       , pkeys :: Map (NonEmpty Name) Name -- maps set of columns to pkconstraint if there is one
                                   -- fully qualifed column mames
                       , tablePKeys :: Map Name Name -- maps table to its pkconstraints
                       , partialfks :: Map (Name,Name) (FKJoinOrder, FKCols)
                       , partialpks :: Map Name  PKCols
                       } deriving (Show)

-- if this list is a primary key, value is Just the table name, otherwise nothing
isPkey :: Config -> (NonEmpty Name) -> Maybe Name
isPkey conf nelist = let canon = N.sort nelist
                     in Map.lookup canon (pkeys conf)

lookupPkey :: Config -> Name -> Name
lookupPkey config tab =
  let x = Map.lookup tab (tablePKeys config)
  in case x of
    Nothing -> error "every table has a pkey. no info for table loaded?"
    Just n -> n

-- if this list of pairs matches a known fk constraint, then the value shows is which is the dim/fact
-- and what the name of the constraint is
isFKRef :: Config -> FKCols -> Maybe FKInstance
isFKRef conf cols = let canon = N.sort cols
                    in Map.lookup canon (fkrefs conf)

isPartialFk :: Config -> (Name,Name) -> Maybe (FKJoinOrder, FKCols)
isPartialFk config (a,b) = Map.lookup (a,b) (partialfks config)


isPartialPk :: Config -> Name -> Maybe PKCols
isPartialPk config n = Map.lookup n (partialpks config)


--- which queries do we want.
--- really: given colname
