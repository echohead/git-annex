{- filenames (not paths) used in views
 -
 - Copyright 2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.View.ViewedFile (
	ViewedFile,
	MkViewedFile,
	viewedFileFromReference,
	viewedFileReuse,
	dirFromViewedFile,
	prop_viewedFile_roundtrips,
) where

import Common.Annex
import Types.View
import Types.MetaData
import qualified Git
import qualified Git.DiffTree as DiffTree
import qualified Git.Branch
import qualified Git.LsFiles
import qualified Git.Ref
import Git.UpdateIndex
import Git.Sha
import Git.HashObject
import Git.Types
import Git.FilePath
import qualified Backend
import Annex.Index
import Annex.Link
import Annex.CatFile
import Logs.MetaData
import Logs.View
import Utility.Glob
import Utility.FileMode
import Types.Command
import Config
import CmdLine.Action

type FileName = String
type ViewedFile = FileName

type MkViewedFile = FilePath -> ViewedFile

{- Converts a filepath used in a reference branch to the
 - filename that will be used in the view.
 -
 - No two filepaths from the same branch should yeild the same result,
 - so all directory structure needs to be included in the output filename
 - in some way.
 -
 - So, from dir/subdir/file.foo, generate file_%dir%subdir%.foo
 -}
viewedFileFromReference :: MkViewedFile
viewedFileFromReference f = concat
	[ escape base
	, if null dirs then "" else "_%" ++ intercalate "%" (map escape dirs) ++ "%"
	, escape $ concat extensions
	]
  where
	(path, basefile) = splitFileName f
	dirs = filter (/= ".") $ map dropTrailingPathSeparator (splitPath path)
	(base, extensions) = splitShortExtensions basefile

	{- To avoid collisions with filenames or directories that contain
	 - '%', and to allow the original directories to be extracted
	 - from the ViewedFile, '%' is escaped to '\%' (and '\' to '\\').
	 -}
	escape :: String -> String
	escape = replace "%" "\\%" . replace "\\" "\\\\"

viewedFileReuse :: MkViewedFile
viewedFileReuse = takeFileName

{- Extracts from a ViewedFile the directory where the file is located on
 - in the reference branch. -}
dirFromViewedFile :: ViewedFile -> FilePath
dirFromViewedFile = joinPath . drop 1 . sep [] ""
  where
  	sep l _ [] = reverse l
	sep l curr (c:cs)
		| c == '%' = sep (reverse curr:l) "" cs
		| c == '\\' = case cs of
			(c':cs') -> sep l (c':curr) cs'
			[] -> sep l curr cs
		| otherwise = sep l (c:curr) cs

prop_viewedFile_roundtrips :: FilePath -> Bool
prop_viewedFile_roundtrips f
	| isAbsolute f = True -- Only relative paths are encoded.
	| any (isPathSeparator) (end f) = True -- Filenames wanted, not directories.
	| otherwise = dir == dirFromViewedFile (viewedFileFromReference f)
  where
	dir = joinPath $ beginning $ splitDirectories f