{- git-annex numcopies configuration and checking
 -
 - Copyright 2014-2015 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.NumCopies (
	module Types.NumCopies,
	module Logs.NumCopies,
	getFileNumCopies,
	getGlobalFileNumCopies,
	getNumCopies,
	deprecatedNumCopies,
	defaultNumCopies,
	numCopiesCheck,
	numCopiesCheck',
	verifyEnoughCopies,
	knownCopies,
) where

import Common.Annex
import qualified Annex
import Types.NumCopies
import Logs.NumCopies
import Logs.Trust
import Annex.CheckAttr
import qualified Remote
import Annex.UUID
import Annex.Content

defaultNumCopies :: NumCopies
defaultNumCopies = NumCopies 1

fromSources :: [Annex (Maybe NumCopies)] -> Annex NumCopies
fromSources = fromMaybe defaultNumCopies <$$> getM id

{- The git config annex.numcopies is deprecated. -}
deprecatedNumCopies :: Annex (Maybe NumCopies)
deprecatedNumCopies = annexNumCopies <$> Annex.getGitConfig

{- Value forced on the command line by --numcopies. -}
getForcedNumCopies :: Annex (Maybe NumCopies)
getForcedNumCopies = Annex.getState Annex.forcenumcopies

{- Numcopies value from any of the non-.gitattributes configuration
 - sources. -}
getNumCopies :: Annex NumCopies
getNumCopies = fromSources
	[ getForcedNumCopies
	, getGlobalNumCopies
	, deprecatedNumCopies
	]

{- Numcopies value for a file, from any configuration source, including the
 - deprecated git config. -}
getFileNumCopies :: FilePath -> Annex NumCopies
getFileNumCopies f = fromSources
	[ getForcedNumCopies
	, getFileNumCopies' f
	, deprecatedNumCopies
	]

{- This is the globally visible numcopies value for a file. So it does
 - not include local configuration in the git config or command line
 - options. -}
getGlobalFileNumCopies :: FilePath  -> Annex NumCopies
getGlobalFileNumCopies f = fromSources
	[ getFileNumCopies' f
	]

getFileNumCopies' :: FilePath  -> Annex (Maybe NumCopies)
getFileNumCopies' file = maybe getGlobalNumCopies (return . Just) =<< getattr
  where
	getattr = (NumCopies <$$> readish)
		<$> checkAttr "annex.numcopies" file

{- Checks if numcopies are satisfied for a file by running a comparison
 - between the number of (not untrusted) copies that are
 - belived to exist, and the configured value. -}
numCopiesCheck :: FilePath -> Key -> (Int -> Int -> v) -> Annex v
numCopiesCheck file key vs = do
	have <- trustExclude UnTrusted =<< Remote.keyLocations key
	numCopiesCheck' file vs have

numCopiesCheck' :: FilePath -> (Int -> Int -> v) -> [UUID] -> Annex v
numCopiesCheck' file vs have = do
	NumCopies needed <- getFileNumCopies file
	return $ length have `vs` needed

{- Verifies that enough copies of a key exist amoung the listed remotes,
 - priting an informative message if not.
 -}
verifyEnoughCopies 
	:: String -- message to print when there are no known locations
	-> Key
	-> NumCopies
	-> [UUID] -- repos to skip (generally untrusted remotes)
	-> [UUID] -- repos that are trusted or already verified to have it
	-> [Remote] -- remotes to check to see if they have it
	-> Annex Bool
verifyEnoughCopies nolocmsg key need skip trusted tocheck = 
	helper [] [] (nub trusted) (nub tocheck)
  where
	helper bad missing have []
		| NumCopies (length have) >= need = return True
		| otherwise = do
			notEnoughCopies key need have (skip++missing) bad nolocmsg
			return False
	helper bad missing have (r:rs)
		| NumCopies (length have) >= need = return True
		| otherwise = do
			let u = Remote.uuid r
			let duplicate = u `elem` have
			haskey <- Remote.hasKey r key
			case (duplicate, haskey) of
				(False, Right True)  -> helper bad missing (u:have) rs
				(False, Left _)      -> helper (r:bad) missing have rs
				(False, Right False) -> helper bad (u:missing) have rs
				_                    -> helper bad missing have rs

notEnoughCopies :: Key -> NumCopies -> [UUID] -> [UUID] -> [Remote] -> String -> Annex ()
notEnoughCopies key need have skip bad nolocmsg = do
	showNote "unsafe"
	showLongNote $
		"Could only verify the existence of " ++
		show (length have) ++ " out of " ++ show (fromNumCopies need) ++ 
		" necessary copies"
	Remote.showTriedRemotes bad
	Remote.showLocations True key (have++skip) nolocmsg

{- Cost ordered lists of remotes that the location log indicates
 - may have a key.
 -
 - Also returns a list of UUIDs that are trusted to have the key
 - (some may not have configured remotes). If the current repository
 - currently has the key, and is not untrusted, it is included in this list.
 -}
knownCopies :: Key -> Annex ([Remote], [UUID])
knownCopies key = do
	(remotes, trusteduuids) <- Remote.keyPossibilitiesTrusted key
	u <- getUUID
	trusteduuids' <- ifM (inAnnex key <&&> (<= SemiTrusted) <$> lookupTrust u)
		( pure (u:trusteduuids)
		, pure trusteduuids
		)
	return (remotes, trusteduuids')
