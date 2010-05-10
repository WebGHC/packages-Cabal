-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.World
-- Copyright   :  (c) Peter Robinson 2009
-- License     :  BSD-like
--
-- Maintainer  :  thaldyron@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Interface to the world-file that contains a list of explicitly
-- requested packages. Meant to be imported qualified.
--
-- A world file entry stores the package-name, package-version, and
-- user flags.
-- For example, the entry generated by
-- # cabal install stm-io-hooks --flags="-debug"
-- looks like this:
-- # stm-io-hooks -any --flags="-debug"
-- To rebuild/upgrade the packages in world (e.g. when updating the compiler)
-- use
-- # cabal install world
--
-----------------------------------------------------------------------------
module Distribution.Client.World (
    insert,
    delete,
    getContents,

    worldPkg,
    isWorldTarget,
    isGoodWorldTarget,
  ) where

import Distribution.Simple.Utils( writeFileAtomic )
import Distribution.Client.Types
    ( UnresolvedDependency(..) )
import Distribution.Package
    ( PackageName(..), Dependency( Dependency ) )
import Distribution.Version( anyVersion )
import Distribution.Text( display, simpleParse )
import Distribution.Verbosity ( Verbosity )
import Distribution.Simple.Utils ( die, info, chattyTry )
import Data.List( unionBy, deleteFirstsBy, nubBy )
import Data.Maybe( isJust, fromJust )
import System.IO.Error( isDoesNotExistError, )
import qualified Data.ByteString.Lazy.Char8 as B
import Prelude hiding ( getContents )

-- | Adds packages to the world file; creates the file if it doesn't
-- exist yet. Version constraints and flag assignments for a package are
-- updated if already present. IO errors are non-fatal.
insert :: Verbosity -> FilePath -> [UnresolvedDependency] -> IO ()
insert = modifyWorld $ unionBy equalUDep

-- | Removes packages from the world file.
-- Note: Currently unused as there is no mechanism in Cabal (yet) to
-- handle uninstalls. IO errors are non-fatal.
delete :: Verbosity -> FilePath -> [UnresolvedDependency] -> IO ()
delete = modifyWorld $ flip (deleteFirstsBy equalUDep)

-- | UnresolvedDependency values are considered equal if they refer to
-- the same package, i.e., we don't care about differing versions or flags.
equalUDep :: UnresolvedDependency -> UnresolvedDependency -> Bool
equalUDep (UnresolvedDependency (Dependency pkg1 _) _)
          (UnresolvedDependency (Dependency pkg2 _) _) = pkg1 == pkg2

-- | Modifies the world file by applying an update-function ('unionBy'
-- for 'insert', 'deleteFirstsBy' for 'delete') to the given list of
-- packages. IO errors are considered non-fatal.
modifyWorld :: ([UnresolvedDependency] -> [UnresolvedDependency]
                -> [UnresolvedDependency])
                        -- ^ Function that defines how
                        -- the list of user packages are merged with
                        -- existing world packages.
            -> Verbosity
            -> FilePath               -- ^ Location of the world file
            -> [UnresolvedDependency] -- ^ list of user supplied packages
            -> IO ()
modifyWorld _ _         _     []   = return ()
modifyWorld f verbosity world pkgs =
  chattyTry "Error while updating world-file. " $ do
    pkgsOldWorld <- getContents world
    -- Filter out packages that are not in the world file:
    let pkgsNewWorld = nubBy equalUDep $ f pkgs pkgsOldWorld
    -- 'Dependency' is not an Ord instance, so we need to check for
    -- equivalence the awkward way:
    if not (all (`elem` pkgsOldWorld) pkgsNewWorld &&
            all (`elem` pkgsNewWorld) pkgsOldWorld)
      then do
        info verbosity "Updating world file..."
        writeFileAtomic world $ unlines
            [ (display pkg) | pkg <- pkgsNewWorld]
      else
        info verbosity "World file is already up to date."


-- | Returns the content of the world file as a list
getContents :: FilePath -> IO [UnresolvedDependency]
getContents world = do
  content <- safelyReadFile world
  let result = map simpleParse (lines $ B.unpack content)
  if all isJust result
    then return $ map fromJust result
    else die "Could not parse world file."
  where
  safelyReadFile :: FilePath -> IO B.ByteString
  safelyReadFile file = B.readFile file `catch` handler
    where
      handler e | isDoesNotExistError e = return B.empty
                | otherwise             = ioError e


-- | A dummy package that represents the world file.
worldPkg :: PackageName
worldPkg = PackageName "world"

-- | Currently we have a silly way of representing the world target as
-- an 'UnresolvedDependency' so we need a way to recognise it.
--
-- We should be using a structured type with various target kinds, like
-- local file, repo package etc.
--
isWorldTarget :: UnresolvedDependency -> Bool
isWorldTarget (UnresolvedDependency (Dependency pkg _) _) =
  pkg == worldPkg

isGoodWorldTarget :: UnresolvedDependency -> Bool
isGoodWorldTarget (UnresolvedDependency (Dependency pkg ver) flags) =
     pkg == worldPkg
  && ver == anyVersion
  && null flags
