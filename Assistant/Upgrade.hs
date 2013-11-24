{- git-annex assistant upgrading
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Assistant.Upgrade where

import Assistant.Common
import Assistant.Restart
import qualified Annex
import Assistant.Alert
import Assistant.DaemonStatus
import Utility.Env
import Types.Distribution
import Logs.Transfer
import Logs.Web
import Logs.Presence
import Logs.Location
import Annex.Content
import qualified Backend
import qualified Types.Backend
import qualified Types.Key
import Assistant.TransferQueue
import Assistant.TransferSlots
import Remote (remoteFromUUID)
import Config.Files
import Utility.ThreadScheduler
import Utility.Tmp
import Utility.UserInfo
import qualified Utility.Lsof as Lsof

import qualified Data.Map as M
import Data.Tuple.Utils

{- Upgrade without interaction in the webapp. -}
unattendedUpgrade :: Assistant ()
unattendedUpgrade = do
	prepUpgrade
	url <- runRestart
	postUpgrade url

prepUpgrade :: Assistant ()
prepUpgrade = do
	void $ addAlert upgradingAlert
	void $ liftIO $ setEnv upgradedEnv "1" True
	prepRestart

postUpgrade :: URLString -> Assistant ()
postUpgrade = postRestart

autoUpgradeEnabled :: Assistant Bool
autoUpgradeEnabled = liftAnnex $ (==) AutoUpgrade . annexAutoUpgrade <$> Annex.getGitConfig

checkSuccessfulUpgrade :: IO Bool
checkSuccessfulUpgrade = isJust <$> getEnv upgradedEnv

upgradedEnv :: String
upgradedEnv = "GIT_ANNEX_UPGRADED"

{- Start downloading the distribution key from the web.
 - Install a hook that will be run once the download is complete,
 - and finishes the upgrade. -}
startDistributionDownload :: GitAnnexDistribution -> Assistant ()
startDistributionDownload d = do
	liftAnnex $ setUrlPresent k u
	hook <- asIO1 $ distributionDownloadComplete d cleanup
	modifyDaemonStatus_ $ \s -> s
		{ transferHook = M.insert k hook (transferHook s) }
	maybe noop (queueTransfer "upgrade" Next (Just f) t)
		=<< liftAnnex (remoteFromUUID webUUID)
	startTransfer t
  where
	k = distributionKey d
	u = distributionUrl d
	f = takeFileName u ++ " (for upgrade)"
	t = Transfer
		{ transferDirection = Download
		, transferUUID = webUUID
		, transferKey = k
		}
	cleanup = liftAnnex $ do
		removeAnnex k
		setUrlMissing k u
		logStatus k InfoMissing

{- Called once the download is done.
 - Passed an action that can be used to clean up the downloaded file.
 -
 - Fsck the key to verify the download.
 -}
distributionDownloadComplete :: GitAnnexDistribution -> Assistant () -> Transfer -> Assistant ()
distributionDownloadComplete d cleanup t 
	| transferDirection t == Download = do
		debug ["finished downloading git-annex distribution"]
		maybe cleanup go =<< liftAnnex (withObjectLoc k fsckit (getM fsckit))
	| otherwise = cleanup
  where
	k = distributionKey d
	fsckit f = case Backend.maybeLookupBackendName (Types.Key.keyBackendName k) of
		Nothing -> return $ Just f
		Just b -> case Types.Backend.fsckKey b of
			Nothing -> return $ Just f
			Just a -> ifM (a k f)
				( return $ Just f
				, return Nothing
				)
	go f = do
		ua <- asIO $ upgradeToDistribution d cleanup f
		fa <- asIO1 failedupgrade
		liftIO $ ua `catchNonAsync` fa
	failedupgrade e = do
		cleanup
		void $ addAlert $ upgradeFailedAlert $ show e

{- The upgrade method varies by OS.
 -
 - In general, find where the distribution was installed before,
 - and unpack the new distribution next to it (in a versioned directory).
 - Then update the programFile to point to the new version.
 -}
upgradeToDistribution :: GitAnnexDistribution -> Assistant () -> FilePath -> Assistant ()
upgradeToDistribution d cleanup f = do
	(program, deleteold) <- unpack
	changeprogram program
	cleanup
	prepUpgrade
	url <- runRestart
	{- At this point, the new assistant is fully running, so
	 - it's safe to delete the old version. -}
	liftIO $ void $ tryIO deleteold
	postUpgrade url
  where
	changeprogram program = liftIO $ do
		unlessM (boolSystem program [Param "version"]) $
			error "New git-annex program failed to run! Not using."
		pf <- programFile
		liftIO $ writeFile pf program
	
#ifdef darwin_HOST_OS
	{- OS X uses a dmg, so mount it, and copy the contents into place. -}
	unpack = do
		error "TODO OSX upgrade code"
#else
	{- Linux uses a tarball (so could other POSIX systems), so
	 - untar it (into a temp directory) and move the directory
	 - into place. -}
	unpack = liftIO $ do
		olddir <- parentDir <$> readProgramFile
		when (null olddir) $
			error $ "Cannot find old distribution bundle; not upgrading."
		newdir <- newVersionLocation d olddir "git-annex.linux."
		whenM (doesDirectoryExist newdir) $
			error $ "Upgrade destination directory " ++ newdir ++ "already exists; not overwriting."
		withTmpDirIn (parentDir newdir) "git-annex.upgrade" $ \tmpdir -> do
			let tarball = tmpdir </> "tar"
			-- Cannot rely on filename extension, and this also
			-- avoids problems if tar doesn't support transparent
			-- decompression.
			void $ boolSystem "sh"
				[ Param "-c"
				, Param $ "zcat < " ++ shellEscape f ++
					" > " ++ shellEscape tarball
				]
			tarok <- boolSystem "tar"
				[ Param "xf"
				, Param tarball
				, Param "--directory", File tmpdir
				]
			unless tarok $
				error $ "failed to untar " ++ f
			let unpacked = tmpdir </> "git-annex.linux"
			unlessM (doesDirectoryExist unpacked) $
				error $ "did not find git-annex.linux in " ++ f
			renameDirectory unpacked newdir
		let deleteold = do
			deleteFromManifest olddir
			let origdir = parentDir olddir </> "git-annex.linux"
			nukeFile origdir
			createSymbolicLink newdir origdir
		return (newdir </> "git-annex", deleteold)
#endif

{- Finds a place to install the new version.
 - Generally, put it in the parent directory of where the old version was
 - installed, and use a version number in the directory name.
 - If unable to write to there, instead put it in the home directory.
 -}
newVersionLocation :: GitAnnexDistribution -> FilePath -> String -> IO FilePath
newVersionLocation d olddir base = go =<< tryIO (writeFile testfile "")
  where
	s = base ++ distributionVersion d
	topdir = parentDir olddir
	newloc = topdir </> s
	testfile = newloc ++ ".test"
	go (Right _) = do
		nukeFile testfile
		return newloc
	go (Left _) = do
		home <- myHomeDir
		return $ home </> s

deleteFromManifest :: FilePath -> IO ()
deleteFromManifest dir = do
	fs <- map (dir </>) . lines <$> catchDefaultIO "" (readFile manifest)
	mapM_ nukeFile fs
	nukeFile manifest
	removeEmptyRecursive dir
  where
	manifest = dir </> "git-annex.MANIFEST"

removeEmptyRecursive :: FilePath -> IO ()
removeEmptyRecursive dir = do
	print ("remove", dir)
	mapM_ removeEmptyRecursive =<< dirContents dir
	void $ tryIO $ removeDirectory dir

{- This is a file that the UpgradeWatcher can watch for modifications to
 - detect when git-annex has been upgraded.
 -}
upgradeFlagFile :: IO (Maybe FilePath)
upgradeFlagFile = ifM usingDistribution
	( Just <$> programFile
	, programPath
	)

{- Sanity check to see if an upgrade is complete and the program is ready
 - to be run. -}
upgradeSanityCheck :: IO Bool
upgradeSanityCheck = ifM usingDistribution
	( doesFileExist =<< programFile
	, do
		-- Ensure that the program is present, and has no writers,
		-- and can be run. This should handle distribution
		-- upgrades, manual upgrades, etc.
		v <- programPath
		case v of
			Nothing -> return False
			Just program -> do
				untilM (doesFileExist program <&&> nowriter program) $
					threadDelaySeconds (Seconds 60)
				boolSystem program [Param "version"]
	)
  where
	nowriter f = null
		. filter (`elem` [Lsof.OpenReadWrite, Lsof.OpenWriteOnly])
		. map snd3
		<$> Lsof.query [f]

usingDistribution :: IO Bool
usingDistribution = isJust <$> getEnv "GIT_ANNEX_STANDLONE_ENV"
