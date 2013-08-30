module Portage.Dependency
  (
    simplify_deps
  , simplifyUseDeps
  , sortDeps

  -- reexports
  , module Portage.Dependency.Builder
  , module Portage.Dependency.Print
  , module Portage.Dependency.Types
  ) where

import Data.Function ( on )
import Data.List ( nub, groupBy, partition, sortBy )
import Data.Maybe ( fromJust, mapMaybe )
import Data.Ord           ( comparing )

import Portage.PackageId

import Portage.Dependency.Builder
import Portage.Dependency.Print
import Portage.Dependency.Types

mergeDRanges :: DRange -> DRange -> DRange
mergeDRanges _ r@(DExact _) = r
mergeDRanges l@(DExact _) _ = l
mergeDRanges (DRange ll lu) (DRange rl ru) = DRange (max ll rl) (min lu ru)

merge_pair :: Dependency -> Dependency -> Dependency
merge_pair (Atom lp ld la) (Atom rp rd ra)
    | lp /= rp = error "merge_pair got different 'PackageName's"
    | la /= ra = error "merge_pair got different 'DAttr's"
    | otherwise = Atom lp (mergeDRanges ld rd) la
merge_pair l r = error $ unwords ["merge_pair can't merge non-atoms:", show l, show r]

-- TODO: remove it in favour of more robust 'normalize_depend'
simplify_group :: [Dependency] -> Dependency
simplify_group [x] = x
simplify_group xs = foldl1 merge_pair xs

-- TODO: remove it in favour of more robust 'normalize_depend'
-- divide packages to groups (by package name), simplify groups, merge again
simplify_deps :: [Dependency] -> [Dependency]
simplify_deps deps = flattenDep $ 
                        (map (simplify_group.nub) $
                            groupBy cmpPkgName $
                                sortBy (comparing getPackagePart) groupable)
                        ++ ungroupable
    where (ungroupable, groupable) = partition ((==Nothing).getPackage) deps
          --
          cmpPkgName p1 p2 = cmpMaybe (getPackage p1) (getPackage p2)
          cmpMaybe (Just p1) (Just p2) = p1 == p2
          cmpMaybe _         _         = False
          --
          flattenDep :: [Dependency] -> [Dependency]
          flattenDep [] = []
          flattenDep (DependAllOf ds:xs) = (concatMap (\x -> flattenDep [x]) ds) ++ flattenDep xs
          flattenDep (x:xs) = x:flattenDep xs
          -- TODO concat 2 dep either in the same group

getPackage :: Dependency -> Maybe PackageName
getPackage (DependAllOf _dependency) = Nothing
getPackage (Atom pn _dr _attrs) = Just pn
getPackage (DependAnyOf _dependency           ) = Nothing
getPackage (DependIfUse  _useFlag    _Dependency) = Nothing

getPackagePart :: Dependency -> PackageName
getPackagePart dep = fromJust (getPackage dep)

-- | remove all Use dependencies that overlap with normal dependencies
simplifyUseDeps :: [Dependency]         -- list where use deps is taken
                    -> [Dependency]     -- list where common deps is taken
                    -> [Dependency]     -- result deps
simplifyUseDeps ds cs =
    let (u,o) = partition isUseDep ds
        c = mapMaybe getPackage cs
    in (mapMaybe (intersectD c) u)++o

intersectD :: [PackageName] -> Dependency -> Maybe Dependency
intersectD fs (DependIfUse u d) = intersectD fs d >>= Just . DependIfUse u
intersectD fs (DependAnyOf ds) =
    let ds' = mapMaybe (intersectD fs) ds
    in if null ds' then Nothing else Just (DependAnyOf ds')
intersectD fs (DependAllOf ds) =
    let ds' = mapMaybe (intersectD fs) ds
    in if null ds' then Nothing else Just (DependAllOf ds')
intersectD fs x =
    let pkg = fromJust $ getPackage x -- this is unsafe but will save from error later
    in if any (==pkg) fs then Nothing else Just x

isUseDep :: Dependency -> Bool
isUseDep (DependIfUse _ _) = True
isUseDep _ = False


sortDeps :: [Dependency] -> [Dependency]
sortDeps = sortBy dsort . map deeper
  where
    deeper :: Dependency -> Dependency
    deeper (DependIfUse u1 d) = DependIfUse u1 $ deeper d
    deeper (DependAllOf ds)   = DependAllOf $ sortDeps ds
    deeper (DependAnyOf ds)  = DependAnyOf $ sortDeps ds
    deeper x = x
    dsort :: Dependency -> Dependency -> Ordering
    dsort (DependIfUse (DUse (_is_u1, u1)) _) (DependIfUse (DUse (_is_u2, u2)) _) = u1 `compare` u2
    dsort (DependIfUse _ _)  (DependAnyOf _)   = LT
    dsort (DependIfUse _ _)  (DependAllOf  _)   = LT
    dsort (DependIfUse _ _)  _                  = GT
    dsort (DependAnyOf _)   (DependAnyOf _)   = EQ
    dsort (DependAnyOf _)  (DependIfUse _ _)   = GT
    dsort (DependAnyOf _)   (DependAllOf _)    = LT
    dsort (DependAnyOf _)   _                  = GT
    dsort (DependAllOf _)    (DependAllOf _)    = EQ
    dsort (DependAllOf _)    (DependIfUse  _ _) = LT
    dsort (DependAllOf _)    (DependAnyOf _)   = GT
    dsort _ (DependIfUse _ _)                   = LT
    dsort _ (DependAllOf _)                     = LT
    dsort _ (DependAnyOf _)                    = LT
    dsort a b = (compare `on` getPackage) a b
