{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE DeriveGeneric #-}

module Horse.Commands.Porcelain
( -- * Basic commands
  Horse.Commands.Porcelain.config
, Horse.Commands.Porcelain.init
, Horse.Commands.Porcelain.add
, Horse.Commands.Porcelain.rm
, Horse.Commands.Porcelain.checkout
, Horse.Commands.Porcelain.commit
, Horse.Commands.Porcelain.diff
, Horse.Commands.Porcelain.log
, Horse.Commands.Porcelain.status
, Horse.Commands.Porcelain.hshow
) where

-- imports

import Prelude hiding (init, log)

import GHC.Generics

-- qualified imports

import qualified System.IO as IO
import qualified System.Directory as Dir

import qualified Data.Hex as Hex
import qualified Data.Default as Default
import qualified Data.Serialize as Serialize
import qualified Data.ByteString as ByteString

import qualified Crypto.Hash.SHA256 as SHA256

import qualified Database.LevelDB.Base as DB
import qualified Database.LevelDB.Internal as DBInternal

-- imported functions

import Data.Maybe (fromJust)
import Data.Either.Unwrap (fromLeft, fromRight)

import Data.Time.Clock (getCurrentTime, utctDay)
import Data.Time.Calendar (toGregorian)

import Text.Printf (printf)

import Control.Monad ((>>=), return)
import Control.Applicative ((<$>), (<*>))
import Control.Monad.IO.Class (liftIO)

-- horse-control imports

import Horse.Types

import qualified Horse.IO as HIO
import qualified Horse.Filesys as Filesys
import qualified Horse.Commands.Plumbing as Plumbing

data Flag
    = Add
    | Delete
    | List
    | Number Integer
    | Squash
    | FastForward
    | All
    | Verbose
    | Quiet
    | Recursive
    | Force
    | Message

config :: [String] -> IO ()
config (name:email:[]) = do -- TODO
    configPath <- Filesys.getConfigPath
    Filesys.createFileWithContents (configPath, ByteString.empty) -- TODO

    let userInfo = UserInfo { name = name, email = email }
    HIO.writeConfig $ Config { userInfo = userInfo }

init :: [String] -> IO ()
init _ = do
    rootDirAlreadyExists <- Dir.doesDirectoryExist Filesys.rootPath

    sequence $ map Filesys.destructivelyCreateDirectory Filesys.directories

    sequence $ map (flip DB.open $ DB.defaultOptions{ DB.createIfMissing = True }) Filesys.databasePaths

    sequence $ map Filesys.createFileWithContents Filesys.serializationPathsAndInitialContents

    currDir <- Dir.getCurrentDirectory
    if rootDirAlreadyExists
        then putStrLn
            $ "Re-initialized existing horse-control repository in"
            ++ currDir ++ "/" ++ Filesys.rootPath
        else putStrLn
            $ "Initialized existing horse-control repository in"
            ++ currDir ++ "/" ++ Filesys.rootPath

    --DBInternal.unsafeClose db
    return ()

status :: [String] -> IO ()
status _ = do
    stagingArea <- HIO.loadStagingArea
    print stagingArea

add :: [String] -> IO ()
add args = do
    stagingArea <- HIO.loadStagingArea
    HIO.writeStagingArea $ stagingArea { modsOrAdds = (modsOrAdds stagingArea) ++ args }

-- TODO: rm from filesystem
rm :: [String] -> IO ()
rm args = do
    stagingArea <- HIO.loadStagingArea
    HIO.writeStagingArea $ stagingArea { deletions = (deletions stagingArea) ++ args }

commit :: [String] -> IO ()
commit args = do
    now <- fmap (toGregorian . utctDay) getCurrentTime
    parentHash <- return Default.def -- TODO
    stagedDiff <- HIO.loadStagingArea >>= getStagedDiff
    config <- HIO.loadConfig
    -- TODO: coalesce commit-creation somehow?
    let hashlessCommit = Commit {
        author                  = userInfo config
        , date                  = now
        , hash                  = Default.def -- no hash yet since commit
                                              -- hasn't been created
        , parentHash            = parentHash
        , secondaryParentHash   = Default.def -- not a merge commit, so
                                              -- no secondary parent
        , diffWithPrimaryParent = stagedDiff
        , message               = message }

    let commitHash = hashCommit hashlessCommit
    let completeCommit = hashlessCommit { hash = commitHash }

    HIO.writeCommit completeCommit commitHash

    HIO.writeHead $ Head { headHash = commitHash }

    HIO.writeStagingArea (Default.def :: StagingArea)

    -- debug code; can delete
    putStrLn "Testing writing of commit: loading written commit: "
    (HIO.loadCommit commitHash) >>= print

    putStrLn $ "[<branch> " ++ (show . ByteString.take 8 $ commitHash)
        ++  "] " ++ message
    putStrLn $ "0" ++ " files changed, " ++ "0" ++ " insertions(+), "
        ++ "0" ++ " deletions(-)"

    where
        message :: String
        message = head args -- TODO

        -- TODO: where does this go?
        hashCommit :: Commit -> Hash
        hashCommit
            = ByteString.take 40
            . Hex.hex
            . SHA256.hash
            . Serialize.encode

        -- TODO
        getStagedDiff :: StagingArea -> IO Diff
        getStagedDiff stagingArea = return Default.def

checkout :: [String] -> IO ()
checkout args = do
    putStrLn $ "running command \"checkout\" with args "
    print args

diff :: [String] -> IO ()
diff args = do
    putStrLn $ "running command \"diff\" with args "
    print args

log :: [String] -> IO ()
log args = do
    putStrLn $ "running command \"log\" with args "
    print args

hshow :: [String] -> IO ()
hshow args = do
    putStrLn $ "running command \"show\" with args "
    print args
