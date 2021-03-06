{- git-annex repository differences
 -
 - Copyright 2015 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Types.Difference (
	Difference(..),
	Differences(..),
	readDifferences,
	getDifferences,
	differenceConfigKey,
	differenceConfigVal,
	hasDifference,
	listDifferences,
) where

import Utility.PartialPrelude
import qualified Git
import qualified Git.Config

import qualified Data.Set as S
import Data.Maybe
import Data.Monoid
import Prelude

-- Describes differences from the v5 repository format.
--
-- The serialization is stored in difference.log, so avoid changes that
-- would break compatability.
--
-- Not breaking compatability is why a list of Differences is used, rather
-- than a sum type. With a sum type, adding a new field for some future
-- difference would serialize to a value that an older version could not
-- parse, even if that new field was not used. With the Differences list,
-- old versions can still parse it, unless the new Difference constructor 
-- is used.
--
-- The constructors intentionally do not have parameters; this is to
-- ensure that any Difference that can be expressed is supported.
-- So, a new repository version would be Version6, rather than Version Int.
data Difference
	= ObjectHashLower
	| OneLevelObjectHash
	| OneLevelBranchHash
	deriving (Show, Read, Ord, Eq, Enum, Bounded)

data Differences
	= Differences (S.Set Difference)
	| UnknownDifferences

instance Eq Differences where
	Differences a == Differences b = a == b
	_ == _ = False -- UnknownDifferences cannot be equal

instance Monoid Differences where
	mempty = Differences S.empty
	mappend (Differences a) (Differences b) = Differences (S.union a b)
	mappend _ _ = UnknownDifferences

readDifferences :: String -> Differences
readDifferences = maybe UnknownDifferences Differences . readish

getDifferences :: Git.Repo -> Differences
getDifferences r = Differences $ S.fromList $
	mapMaybe getmaybe [minBound .. maxBound]
  where
	getmaybe d = case Git.Config.isTrue =<< Git.Config.getMaybe (differenceConfigKey d) r of
		Just True -> Just d
		_ -> Nothing

differenceConfigKey :: Difference -> String
differenceConfigKey ObjectHashLower = tunable "objecthashlower"
differenceConfigKey OneLevelObjectHash = tunable "objecthash1"
differenceConfigKey OneLevelBranchHash = tunable "branchhash1"

differenceConfigVal :: Difference -> String
differenceConfigVal _ = Git.Config.boolConfig True

tunable :: String -> String
tunable k = "annex.tune." ++ k

hasDifference :: Difference -> Differences -> Bool
hasDifference d (Differences s) = S.member d s
hasDifference _ UnknownDifferences = False

listDifferences :: Differences -> [Difference]
listDifferences (Differences s) = S.toList s
listDifferences UnknownDifferences = []
