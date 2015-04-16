{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

-- imports

import Test.Tasty
import Test.Tasty.HUnit

import Control.Monad.Trans.Either
import Control.Monad.IO.Class (liftIO)

-- qualified imports

import qualified System.IO as IO
import qualified System.Directory as D

import qualified Data.Hex as Hex
import qualified Data.Default as Default
import qualified Data.Serialize as Serialize
import qualified Data.ByteString as ByteString

import qualified Crypto.Hash.SHA256 as SHA256

import qualified Database.LevelDB.Base as DB
import qualified Database.LevelDB.Internal as DBInternal

-- imported functions

import Data.List (sort)

import System.Exit (exitSuccess)

import Data.Time.Clock (getCurrentTime, utctDay)
import Data.Time.Calendar (toGregorian)

import Control.Monad ((>>=), return, when)
import Control.Applicative ((<$>), (<*>))
import Control.Monad.IO.Class (liftIO)

import Data.Either.Combinators (isLeft, isRight, fromLeft, fromRight)

-- horse imports

import Horse.Types

import qualified Horse.IO as H
import qualified Horse.Utils as H
import qualified Horse.Commands as H
import qualified Horse.Constants as H

-- | Runs a test in its own empty directory.
-- | Effectively, it isolates it from all other tests.
runTest :: Assertion -> Assertion
runTest t = do
    testDirectory <- getTestDirectory
    D.createDirectory testDirectory
    D.setCurrentDirectory testDirectory

    t

    D.setCurrentDirectory ".."
    D.removeDirectoryRecursive testDirectory
    where
        -- | Gives a name of a directory that is pretty much guaranteed to
        -- | exist, so it's free for creation.
        getTestDirectory :: IO FilePath
        getTestDirectory = (map formatChar . show) <$> getCurrentTime
            where
                -- | Some characters can't be in directory names.
                formatChar :: Char -> Char
                formatChar ' ' = '-'
                formatChar '.' = '-'
                formatChar ':' = '-'
                formatChar ch = ch

createFileWithContents :: FilePath -> String -> IO ()
createFileWithContents filepath contents = do
    handle <- IO.openFile filepath IO.WriteMode
    IO.hPutStr handle contents
    IO.hClose handle

quietCommit :: Maybe String -> EitherT Error IO Commit
quietCommit = (flip H.commit $ Just Quiet)

-- | Test the `horse log` command
testLog :: Assertion
testLog = do
    H.init (Just Quiet)
    eitherSuccess <- runEitherT $ do
        let messages = map Just ["A", "B", "C", "D"]
        commits <- mapM quietCommit messages

        history <- reverse <$> H.log Nothing Nothing (Just Quiet)
        liftIO $ commits @?= history
    when (isLeft eitherSuccess) $ do
        assertFailure (fromLeft undefined eitherSuccess)
    return ()

-- | Test the `horse log` command
testLogEdgeCase1 :: Assertion
testLogEdgeCase1 = do
    H.init (Just Quiet)
    eitherSuccess <- runEitherT $ do
        history <- reverse <$> H.log Nothing Nothing (Just Quiet)

        liftIO $ [] @?= history

    when (isLeft eitherSuccess) $ do
        assertFailure (fromLeft undefined eitherSuccess)
    return ()

-- | Test the `horse log` command
testLogEdgeCase2 :: Assertion
testLogEdgeCase2 = do
    H.init (Just Quiet)
    eitherSuccess <- runEitherT $ do
        let messages = map Just ["A", "B", "C", "D"]
        commits <- mapM quietCommit messages

        let ref = H.hashToString . hash $ commits !! 2
        history <- reverse <$> H.log (Just ref) Nothing (Just Quiet)
        liftIO $ (take (2+1) commits) @?= history
    when (isLeft eitherSuccess) $ do
        assertFailure (fromLeft undefined eitherSuccess)
    return ()

-- | Test the `horse log` command
testLogEdgeCase3 :: Assertion
testLogEdgeCase3 = do
    H.init (Just Quiet)
    eitherSuccess <- runEitherT $ do
        let messages = map Just ["A", "B", "C", "D"]
        commits <- mapM quietCommit messages

        let ref = H.hashToString . hash $ head commits
        history <- reverse <$> H.log (Just ref) Nothing (Just Quiet)
        liftIO $ ([head commits]) @?= history
    when (isLeft eitherSuccess) $ do
        assertFailure (fromLeft undefined eitherSuccess)
    return ()

-- | Test the `horse stage` command
testStage :: Assertion
testStage = do
    H.init (Just Quiet)

    createFileWithContents "a" "a"

    runEitherT $ H.stage "a"

    eitherStagingArea <- runEitherT H.loadStagingArea

    (Right ["a"]) @?= (adds <$> eitherStagingArea)
    (Right [])    @?= (mods <$> eitherStagingArea)
    (Right [])    @?= (dels <$> eitherStagingArea)

-- | Test the `horse stage` command when given a directory
testStageDirectory :: Assertion
testStageDirectory = do
    H.init (Just Quiet)

    D.createDirectory "dir"
    createFileWithContents "dir/a" "a"

    runEitherT $ H.stage "dir/a"
    runEitherT $ quietCommit Nothing

    createFileWithContents "dir/b" "b"

    runEitherT $ H.stage "dir"

    --eitherStagingArea <- runEitherT H.loadStagingArea
    return ()
    --(Right ["dir/b"]) @?= (adds <$> eitherStagingArea)
    --(Right ["dir/a"]) @?= (mods <$> eitherStagingArea)
    --(Right [])        @?= (dels <$> eitherStagingArea)

-- | No files should result in an empty staging area
testStatusCase1 :: Assertion
testStatusCase1 = do
    H.init (Just Quiet)

    eitherStatus <- runEitherT $ H.status (Just Quiet)

    assertBool "`status` command should not fail" (isRight eitherStatus)
    stagingArea <$> eitherStatus @?= Right Default.def

-- | No files should result in no untracked files
testStatusCase2 :: Assertion
testStatusCase2 = do
    H.init (Just Quiet)

    eitherStatus <- runEitherT $ H.status (Just Quiet)

    assertBool "`status` command should not fail" (isRight eitherStatus)
    unstagedFiles <$> eitherStatus @?= Right Default.def

-- | Checks that we correctly identify all unstaged files
testStatusCase3 :: Assertion
testStatusCase3 = do
    H.init (Just Quiet)

    createFileWithContents "a" "a"
    eitherStatus <- runEitherT $ H.status (Just Quiet)

    assertBool "`status` command should not fail" (isRight eitherStatus)
    let status = fromRight undefined eitherStatus

    stagingArea status @?= Default.def
    unstagedFiles status @?= ["a"]
    return ()

-- | Checks that the staging area is properly cleared after commits
testStatusCase4 :: Assertion
testStatusCase4 = do
    H.init (Just Quiet)

    createFileWithContents "a" "a"
    runEitherT $ H.stage "a"

    runEitherT $ quietCommit (Just "added \"a\"")

    eitherStatus <- runEitherT $ H.status (Just Quiet)
    assertBool "`status` command should not fail" (isRight eitherStatus)
    let status = fromRight undefined eitherStatus
    status @?= Default.def

    createFileWithContents "b" "b"
    runEitherT $ H.stage "b"
    runEitherT $ quietCommit (Just "added \"b\"")

    appendFile "a" "aaaa"

    eitherStatus <- runEitherT $ H.status (Just Quiet)
    assertBool "`status` command should not fail" (isRight eitherStatus)
    let status = fromRight undefined eitherStatus
    status @?= Status (StagingArea [] [] []) ["a"]

    return ()

-- Checks that the staging area recognizes modifications to files
testStatusCase5 :: Assertion
testStatusCase5 = do
    H.init (Just Quiet)

    createFileWithContents "a" "a"
    runEitherT $ H.stage "a"
    runEitherT $ quietCommit Nothing

    appendFile "a" "bcd"
    runEitherT $ H.stage "a"
    eitherStatus <- runEitherT $ H.status (Just Quiet)
    assertBool "`status` command should not fail" (isRight eitherStatus)
    let status = fromRight undefined eitherStatus
    status @?= Status (StagingArea [] ["a"] []) []

    return ()

-- | Test the `horse init` command
testInit :: Assertion
testInit = do
    H.init (Just Quiet)
    rootDirectoryCreated <- D.doesDirectoryExist H.repositoryDataDir
    rootDirectoryCreated @?= True

-- | Verify that a command failed gracefully, as it should when run
-- | without a repository in which to execute
testNoRepo :: EitherT Error IO a -> Assertion
testNoRepo = (=<<) ((@?=) True . isLeft) . runEitherT

-- | Test the command `horse status` when run without a repository
testNoRepoStatus :: Assertion
testNoRepoStatus = testNoRepo $ H.status (Just Quiet)

-- | Test the command `horse stage` when run without a repository
testNoRepoStage :: Assertion
testNoRepoStage = testNoRepo $ H.stage Default.def

-- | Test the command `horse checkout` when run without a repository
testNoRepoCheckout :: Assertion
testNoRepoCheckout = testNoRepo $ H.checkout Default.def (Just Quiet)

-- | Test the command `horse commit` when run without a repository
testNoRepoCommit :: Assertion
testNoRepoCommit = testNoRepo $ quietCommit Default.def

-- | Test the command `horse show` when run without a repository
testNoRepoShow :: Assertion
testNoRepoShow = testNoRepo $ H.show Default.def (Just Quiet)

-- | Test the command `horse log` when run without a repository
testNoRepoLog :: Assertion
testNoRepoLog = testNoRepo $ H.log Default.def Default.def Default.def

-- | Tests diffing. Assumes working `horse commit`
testCheckout :: Assertion
testCheckout = do 
    H.init (Just Quiet)

    ----------------

    createFileWithContents "a" "1"

    runEitherT $ H.stage "a"
    runEitherT $ quietCommit Nothing

    ----------------

    D.removeFile "a" >> createFileWithContents "a" "2"
    createFileWithContents "b" "2"

    runEitherT $ H.stage "a"
    runEitherT $ H.stage "b"
    runEitherT $ quietCommit Nothing

    ----------------

    D.removeFile "a" >> createFileWithContents "a" "3"
    D.removeFile "b"

    runEitherT $ H.stage "a"
    runEitherT $ H.stage "b"
    runEitherT $ quietCommit Nothing

    ----------------

    -- try multiple combinations of gaps and orders and such
    test1
    test2
    test3
    test2
    test1
    test3
    test1

    return ()
    where   
        first :: IO Hash
        first
            = fromRight undefined
            <$> (runEitherT
                        $ (hash . last)
                            <$> (H.log Nothing Nothing (Just Quiet)))
        
        second :: IO Hash
        second
            = fromRight undefined
            <$> (runEitherT
                        $ (hash . head . tail)
                            <$> (H.log Nothing Nothing (Just Quiet)))

        third :: IO Hash
        third
            = fromRight undefined
            <$> (runEitherT
                        $ (hash . head)
                            <$> (H.log Nothing Nothing (Just Quiet)))

        test1 :: Assertion
        test1 = do
            first >>= (quietCheckout) . H.hashToString

            aContents <- readFile "a"
            aContents @?= "1"

            bExists <- D.doesFileExist "b"
            (not bExists) @? "`b` should not exist."
            return ()

        test2 :: Assertion
        test2 = do
            second >>= (quietCheckout) . H.hashToString

            aContents <- readFile "a"
            aContents @?= "2"

            aContents <- readFile "b"
            aContents @?= "2"
            return ()

        test3 :: Assertion
        test3 = do
            third >>= (quietCheckout) . H.hashToString

            aContents <- readFile "a"
            aContents @?= "3"

            bExists <- D.doesFileExist "b"
            (not bExists) @? "`b` should not exist."
            return ()

        quietCheckout :: String -> IO ()
        quietCheckout ref = fromRight undefined <$> (runEitherT $ H.checkout ref (Just Quiet))

-- unstaged files
testStatusFromSubdir :: Assertion
testStatusFromSubdir = do
    H.init (Just Quiet)

    D.createDirectory "a"
    D.createDirectory "a/b"
    D.createDirectory "a/b/c"
    createFileWithContents "a/b/file" "x"
    D.setCurrentDirectory "a/b/c"

    eitherStatus <- runEitherT $ H.status (Just Quiet)
    assertBool "`status` command should not fail" (isRight eitherStatus)
    let status = fromRight undefined eitherStatus
    status @?= Status (StagingArea [] [] []) ["a/b/file"]

    D.setCurrentDirectory "../../.."

testStageFromSubdir :: Assertion
testStageFromSubdir = do
    H.init (Just Quiet)

    D.createDirectory "a"
    createFileWithContents "a/x" "x"
    D.setCurrentDirectory "a"

    runEitherT $ H.stage "x"

    -- test that current directory did not change
    currDirContents <- D.getDirectoryContents "."
    (sort currDirContents) @?= (sort [".", "..", "x"])
    D.setCurrentDirectory ".."

    eitherStagingArea <- runEitherT H.loadStagingArea
    eitherStagingArea @?= Right (StagingArea ["a/x"] [] [])

testCheckoutFromSubdir :: Assertion
testCheckoutFromSubdir = do
    H.init (Just Quiet)

    ----------------

    D.createDirectory "dir"
    createFileWithContents "dir/a" "1"

    runEitherT $ H.stage "dir/a"
    runEitherT $ quietCommit Nothing

    ----------------

    D.removeFile "dir/a" >> createFileWithContents "dir/a" "2"
    createFileWithContents "dir/b" "2"

    runEitherT $ H.stage "dir/a"
    runEitherT $ H.stage "dir/b"
    runEitherT $ quietCommit Nothing

    ----------------

    D.removeFile "dir/a" >> createFileWithContents "dir/a" "3"
    D.removeFile "dir/b"

    runEitherT $ H.stage "dir/a"
    runEitherT $ H.stage "dir/b"
    runEitherT $ quietCommit Nothing

    ----------------

    -- try multiple combinations of gaps and orders and such
    test1
    test2
    test3
    test2
    test1
    test3
    test1

    return ()
    where   
        first :: IO Hash
        first
            = fromRight undefined
            <$> (runEitherT
                        $ (hash . last)
                            <$> (H.log Nothing Nothing (Just Quiet)))
        
        second :: IO Hash
        second
            = fromRight undefined
            <$> (runEitherT
                        $ (hash . head . tail)
                            <$> (H.log Nothing Nothing (Just Quiet)))

        third :: IO Hash
        third
            = fromRight undefined
            <$> (runEitherT
                        $ (hash . head)
                            <$> (H.log Nothing Nothing (Just Quiet)))

        test1 :: Assertion
        test1 = do
            D.setCurrentDirectory "dir"
            first >>= (quietCheckout) . H.hashToString

            c <- D.getDirectoryContents "."

            aContents <- readFile "a"
            aContents @?= "1"

            bExists <- D.doesFileExist "b"
            (not bExists) @? "`b` should not exist."

            D.setCurrentDirectory ".."

        test2 :: Assertion
        test2 = do
            D.setCurrentDirectory "dir"
            second >>= (quietCheckout) . H.hashToString

            aContents <- readFile "a"
            aContents @?= "2"

            aContents <- readFile "b"
            aContents @?= "2"

            D.setCurrentDirectory ".."

        test3 :: Assertion
        test3 = do
            D.setCurrentDirectory "dir"
            third >>= (quietCheckout) . H.hashToString

            aContents <- readFile "a"
            aContents @?= "3"

            bExists <- D.doesFileExist "b"
            (not bExists) @? "`b` should not exist."

            D.setCurrentDirectory ".."

        quietCheckout :: String -> IO ()
        quietCheckout ref = fromRight undefined <$> (runEitherT $ H.checkout ref (Just Quiet))

testCommitFromSubdir :: Assertion
testCommitFromSubdir = do
    H.init (Just Quiet)

    ----------------

    D.createDirectory "dir"
    D.setCurrentDirectory "dir"
    createFileWithContents "a" "1"

    runEitherT $ H.stage "a"
    runEitherT $ quietCommit Nothing
    --cd <- D.getCurrentDirectory
    --putStrLn $ "CDURRR: " ++ cd
    --c <- D.getDirectoryContents "."
    --putStrLn $ "CNT:" ++ (show c)
    ----------------

    D.removeFile "a" >> createFileWithContents "a" "2"
    createFileWithContents "b" "2"

    runEitherT $ H.stage "a"
    runEitherT $ H.stage "b"
    runEitherT $ quietCommit Nothing
    ----------------

    D.removeFile "a" >> createFileWithContents "a" "3"
    D.removeFile "b"

    runEitherT $ H.stage "a"
    runEitherT $ H.stage "b"
    runEitherT $ quietCommit Nothing

    ----------------

    -- try multiple combinations of gaps and orders and such
    test1
    test2
    test3
    test2
    test1
    test3
    test1

    D.setCurrentDirectory ".."

    return ()
    where   
        first :: IO Hash
        first
            = fromRight undefined
            <$> (runEitherT
                        $ (hash . last)
                            <$> (H.log Nothing Nothing (Just Quiet)))
        
        second :: IO Hash
        second
            = fromRight undefined
            <$> (runEitherT
                        $ (hash . head . tail)
                            <$> (H.log Nothing Nothing (Just Quiet)))

        third :: IO Hash
        third
            = fromRight undefined
            <$> (runEitherT
                        $ (hash . head)
                            <$> (H.log Nothing Nothing (Just Quiet)))

        test1 :: Assertion
        test1 = do
            first >>= (quietCheckout) . H.hashToString

            c <- D.getDirectoryContents "."

            aContents <- readFile "a"
            aContents @?= "1"

            bExists <- D.doesFileExist "b"
            (not bExists) @? "`b` should not exist."

        test2 :: Assertion
        test2 = do
            second >>= (quietCheckout) . H.hashToString

            aContents <- readFile "a"
            aContents @?= "2"

            aContents <- readFile "b"
            aContents @?= "2"

        test3 :: Assertion
        test3 = do
            third >>= (quietCheckout) . H.hashToString

            aContents <- readFile "a"
            aContents @?= "3"

            bExists <- D.doesFileExist "b"
            (not bExists) @? "`b` should not exist."

        quietCheckout :: String -> IO ()
        quietCheckout ref = fromRight undefined <$> (runEitherT $ H.checkout ref (Just Quiet))

testShowFromSubdir :: Assertion
testShowFromSubdir = do
    H.init (Just Quiet)

    ----------------

    D.createDirectory "dir"
    D.setCurrentDirectory "dir"
    createFileWithContents "a" "1"

    runEitherT $ H.stage "a"
    eitherCommit <- runEitherT $ quietCommit Nothing

    assertBool "`commit` should not fail." $ isRight eitherCommit
    let commit = fromRight undefined eitherCommit

    eitherShownCommit <- runEitherT $ H.show (Just $ H.hashToString $ hash commit) (Just Quiet)
    assertBool "`commit` should not fail." $ isRight eitherShownCommit
    let shownCommit = fromRight undefined eitherShownCommit

    shownCommit @?= commit

    D.setCurrentDirectory ".."

testLogFromSubdir :: Assertion
testLogFromSubdir = do
    H.init (Just Quiet)
    eitherSuccess <- runEitherT $ do
        liftIO $ D.createDirectory "dir"
        liftIO $ D.setCurrentDirectory "dir"

        let messages = map Just ["A", "B", "C", "D"]
        commits <- mapM quietCommit messages

        history <- reverse <$> H.log Nothing Nothing (Just Quiet)
        liftIO $ commits @?= history
    D.setCurrentDirectory ".."
    when (isLeft eitherSuccess) $ do
        assertFailure (fromLeft undefined eitherSuccess)
    return ()

tests :: TestTree
tests = testGroup "unit tests"
    [ testCase
        "Testing command `status` run without a repo"
        (runTest testNoRepoStatus)
    , testCase
        "Testing command `stage` run without a repo"
        (runTest testNoRepoStage)
    , testCase
        "Testing command `checkout` run without a repo"
        (runTest testNoRepoCheckout)
    , testCase
        "Testing command `commit` run without a repo"
        (runTest testNoRepoCommit)
    , testCase
        "Testing command `show` run without a repo"
        (runTest testNoRepoShow)
    , testCase
        "Testing command `log` run without a repo"
        (runTest testNoRepoLog)
    , testCase
        "Testing `horse init`"
        (runTest testInit)
    , testCase
        "Testing `horse log`"
        (runTest testLog)
    , testCase
        "Testing `horse log` (edge case 1)"
        (runTest testLogEdgeCase1)
    , testCase
        "Testing `horse log` (edge case 2)"
        (runTest testLogEdgeCase2)
    , testCase
        "Testing `horse log` (edge case 3)"
        (runTest testLogEdgeCase3)
    , testCase
        "Testing command `stage`"
        (runTest testStage)
    , testCase
        "Testing command `stage` when given a directory"
        (runTest testStageDirectory)
    , testCase
        "Testing command `status` (case 1)"
        (runTest testStatusCase1)
    , testCase
        "Testing command `status` (case 2)"
        (runTest testStatusCase2)
    , testCase
        "Testing command `status` (case 3)"
        (runTest testStatusCase3)
    , testCase
        "Testing command `status` (case 4)"
        (runTest testStatusCase4)
    , testCase
        "Testing command `status` (case 5)"
        (runTest testStatusCase5)
    , testCase
        "Testing diffs being stored in commits"
        (runTest testCheckout)
    , testCase
        "Testing executing command `status` from subdirectory"
        (runTest testStatusFromSubdir)
    , testCase
        "Testing executing command `stage` from subdirectory"
        (runTest testStageFromSubdir)
    , testCase
        "Testing executing command `checkout` from subdirectory"
        (runTest testCheckoutFromSubdir)
    , testCase
        "Testing executing command `commit` from subdirectory"
        (runTest testCommitFromSubdir)
    , testCase
        "Testing executing command `show` from subdirectory"
        (runTest testShowFromSubdir)
    , testCase
        "Testing executing command `log` from subdirectory"
        (runTest testLogFromSubdir)
    ]

main :: IO ()
main = defaultMain tests
