{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}

-- | This module provides a large suite of utilities that resemble Unix
--  utilities.
--
--  Many of these commands are just existing Haskell commands renamed to match
--  their Unix counterparts:
--
-- >>> :set -XOverloadedStrings
-- >>> cd "/tmp"
-- >>> pwd
-- FilePath "/tmp"
--
-- Some commands are `Shell`s that emit streams of values.  `view` prints all
-- values in a `Shell` stream:
--
-- >>> view (ls "/usr")
-- FilePath "/usr/lib"
-- FilePath "/usr/src"
-- FilePath "/usr/sbin"
-- FilePath "/usr/include"
-- FilePath "/usr/share"
-- FilePath "/usr/games"
-- FilePath "/usr/local"
-- FilePath "/usr/bin"
-- >>> view (find "Browser.py" "/usr/lib")
-- FilePath "lib/python3.2/idlelib/ObjectBrowser.py"
-- FilePath "lib/python3.2/idlelib/PathBrowser.py"
-- FilePath "lib/python3.2/idlelib/RemoteObjectBrowser.py"
-- FilePath "lib/python3.2/idlelib/ClassBrowser.py"
--
-- Use `fold` to reduce the output of a `Shell` stream:
--
-- >>> import qualified Control.Foldl as Fold
-- >>> fold (ls "/usr") Fold.length
-- 8
-- >>> fold (find "Browser.py" "/usr/lib") Fold.head
-- Just (FilePath "/usr/lib/python3.2/idlelib/ObjectBrowser.py")
--
-- Create files using `output`:
--
-- >>> output "foo.txt" ("123" <|> "456" <|> "ABC")
-- >>> realpath "foo.txt"
-- FilePath "/tmp/foo.txt"
--
-- Read in files using `input`:
--
-- >>> stdout (input "foo.txt")
-- 123
-- 456
-- ABC
--
-- Commands like `grep`, `sed` and `find` accept arbitrary `Pattern`s
--
-- >>> stdout (grep ("1" <|> "B") (input "foo.txt"))
-- 123
-- ABC
-- >>> let exclaim = fmap (<> "!") (plus digit)
-- >>> stdout (sed exclaim (input "foo.txt"))
-- 123!
-- 456!
-- ABC
--
--  You can also build up more sophisticated `Shell` programs using `sh` in
--  conjunction with @do@ notation:
--
-- >{-# LANGUAGE OverloadedStrings #-}
-- >
-- >import Turtle
-- >
-- >main = sh example
-- >
-- >example = do
-- >    -- Read in file names from "files1.txt" and "files2.txt"
-- >    file <- fmap fromText (input "files1.txt" <|> input "files2.txt")
-- >
-- >    -- Stream each file to standard output only if the file exists
-- >    True <- liftIO (testfile file)
-- >    txt  <- input file
-- >    liftIO (echo txt)
--
-- See "Turtle.Tutorial" for an extended tutorial explaining how to use this
-- library in greater detail.

module Turtle.Prelude (
    -- * IO
      system
    , echo
    , err
#if MIN_VERSION_base(4,7,0)
    , export
    , unset
#endif
#if MIN_VERSION_base(4,6,0)
    , need
#endif
    , env
    , cd
    , pwd
    , home
    , realpath
    , mv
    , mkdir
    , mktree
    , cp
    , rm
    , rmdir
    , rmtree
    , du
    , testfile
    , testdir
    , date
    , datefile
    , touch
    , time
    , sleep
    , exit
    , die

    -- * Protected
    , mktemp
    , mktempdir
    , fork
    , wait

    -- * Shell
    , stream
    , stdin
    , input
    , stdout
    , stderr
    , output
    , append
    , ls
    , lstree
    , cat
    , grep
    , sed
    , find
    , yes
    , limit
    , limitWhile
    ) where

import Control.Applicative (Alternative(..))
import Control.Concurrent.Async (Async, async, cancel, withAsync, wait)
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Foldl (FoldM(..))
import Control.Monad (msum)
#ifdef mingw32_HOST_OS
import Data.Bits ((.&.))
#endif
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime, getCurrentTime)
import qualified Data.Text    as Text
import qualified Data.Text.IO as Text
import qualified Filesystem
import Filesystem.Path.CurrentOS (FilePath, (</>))
import qualified Filesystem.Path.CurrentOS as Filesystem
import System.Clock (Clock(..), TimeSpec(..), getTime)
import System.Environment (
#if MIN_VERSION_base(4,7,0)
    setEnv,
    unsetEnv,
#endif
#if MIN_VERSION_base(4,6,0)
    lookupEnv,
#endif
    getEnvironment )
import System.Directory (getPermissions, readable)
import System.Exit (ExitCode(..), exitWith)
import System.IO (Handle)
import qualified System.IO as IO
import System.IO.Temp (createTempDirectory, openTempFile)
import qualified System.Process as Process
#ifdef mingw32_HOST_OS
import qualified System.Win32 as Win32
#else
import System.Posix (openDirStream, readDirStream, closeDirStream, touchFile)
#endif
import Prelude hiding (FilePath)

import Turtle.Pattern (Pattern, anyChar, inside, match)
import Turtle.Protected
import Turtle.Shell

{-| Call a system command, and retrieve the exit code

    The command inherits @stdout@ and @stderr@ for the current process
-}
system
    :: Text
    -- ^ Command
    -> Shell Text
    -- ^ Lines of standard input
    -> IO ExitCode
    -- ^ Exit code
system cmd s = do
    let p = (Process.shell (Text.unpack cmd))
            { Process.std_in  = Process.CreatePipe
            , Process.std_out = Process.Inherit
            , Process.std_err = Process.Inherit
            }
    (Just hIn, Nothing, Nothing, ph) <- liftIO (Process.createProcess p)
    let feedIn = sh (do
            txt <- s
            liftIO (Text.hPutStrLn hIn txt) )
    withAsync feedIn (\_ -> liftIO (Process.waitForProcess ph) )

{-| Stream a system command's @stdout@ as lines of `Text`

    The command inherits @stderr@ for the current process
-}
stream
    :: Text
    -- ^ Command
    -> Shell Text
    -- ^ Lines of standard input
    -> Shell Text
    -- ^ Lines of standard output
stream cmd s = do
    let p = (Process.shell (Text.unpack cmd))
            { Process.std_in  = Process.CreatePipe
            , Process.std_out = Process.CreatePipe
            , Process.std_err = Process.Inherit
            }
    (Just hIn, Just hOut, Nothing, _) <- liftIO (Process.createProcess p)
    let feedIn = sh (do
            txt <- s
            liftIO (Text.hPutStrLn hIn txt) )
    _ <- with (fork feedIn)
    handlein hOut

-- | Print to @stdout@
echo :: Text -> IO ()
echo = Text.putStrLn

-- | Print to @stderr@
err :: Text -> IO ()
err = Text.hPutStrLn IO.stderr

#if MIN_VERSION_base(4,7,0)
-- | Set or modify an environment variable
export :: Text -> Text -> IO ()
export key val = setEnv (Text.unpack key) (Text.unpack val)

-- | Delete an environment variable
unset :: Text -> IO ()
unset key = unsetEnv (Text.unpack key)
#endif

#if MIN_VERSION_base(4,6,0)
-- | Look up an environment variable
need :: Text -> IO (Maybe Text)
need key = fmap (fmap Text.pack) (lookupEnv (Text.unpack key))
#endif

-- | Retrieve all environment variables
env :: IO [(Text, Text)]
env = fmap (fmap toTexts) getEnvironment
  where
    toTexts (key, val) = (Text.pack key, Text.pack val)

-- | Change the current directory
cd :: FilePath -> IO ()
cd = Filesystem.setWorkingDirectory

-- | Get the current directory
pwd :: IO FilePath
pwd = Filesystem.getWorkingDirectory

-- | Get the home directory
home :: IO FilePath
home = Filesystem.getHomeDirectory

-- | Canonicalize a path
realpath :: FilePath -> IO FilePath
realpath = Filesystem.canonicalizePath

#ifdef mingw32_HOST_OS
fILE_ATTRIBUTE_REPARSE_POINT :: Win32.FileAttributeOrFlag
fILE_ATTRIBUTE_REPARSE_POINT = 1024

reparsePoint :: Win32.FileAttributeOrFlag -> Bool
reparsePoint attr = fILE_ATTRIBUTE_REPARSE_POINT .&. attr /= 0
#endif

{-| List all immediate children of the given directory, excluding @\".\"@ and
    @\"..\"@
-}
ls :: FilePath -> Shell FilePath
ls path = Shell (\(FoldM step begin done) -> do
    x0 <- begin
    let path' = Filesystem.encodeString path
    canRead <- fmap readable (getPermissions path')
#ifdef mingw32_HOST_OS
    reparse <- fmap reparsePoint (Win32.getFileAttributes path')
    if (canRead && not reparse)
        then bracket
            (Win32.findFirstFile (Filesystem.encodeString (path </> "*")))
            (\(h, _) -> Win32.findClose h)
            (\(h, fdat) -> do
                let loop x = do
                        file' <- Win32.getFindDataFileName fdat
                        let file = Filesystem.decodeString file'
                        x' <- if (file' /= "." && file' /= "..")
                            then step x (path </> file)
                            else return x
                        more <- Win32.findNextFile h fdat
                        if more then loop $! x' else done x'
                loop $! x0 )
        else done x0 )
#else
    if canRead
        then bracket (openDirStream path') closeDirStream (\dirp -> do
            let loop x = do
                    file' <- readDirStream dirp
                    case file' of
                        "" -> done x
                        _  -> do
                            let file = Filesystem.decodeString file'
                            x' <- if (file' /= "." && file' /= "..")
                                then step x (path </> file)
                                else return x
                            loop $! x'
            loop $! x0 )
        else done x0 )
#endif

-- | List all recursive descendents of the given directory
lstree :: FilePath -> Shell FilePath
lstree path = do
    child <- ls path
    isDir <- liftIO (testdir child)
    if isDir
        then return child <|> lstree child
        else return child

-- | Move a file or directory
mv :: FilePath -> FilePath -> IO ()
mv = Filesystem.rename

-- | Create a directory
mkdir :: FilePath -> IO ()
mkdir = Filesystem.createDirectory False

-- | Create a directory tree (equivalent to @mkdir -p@)
mktree :: FilePath -> IO ()
mktree = Filesystem.createTree

-- | Copy a file
cp :: FilePath -> FilePath -> IO ()
cp = Filesystem.copyFile

-- | Remove a file
rm :: FilePath -> IO ()
rm = Filesystem.removeFile

-- | Remove a directory
rmdir :: FilePath -> IO ()
rmdir = Filesystem.removeFile

-- | Remove a directory tree
rmtree :: FilePath -> IO ()
rmtree = Filesystem.removeTree

-- | Get a file or directory's size
du :: FilePath -> IO Integer
du = Filesystem.getSize

-- | Check if a file exists
testfile :: FilePath -> IO Bool
testfile = Filesystem.isFile

-- | Check if a directory exists
testdir :: FilePath -> IO Bool
testdir = Filesystem.isDirectory

{-| Touch a file, updating the access and modification times to the current time

    Creates the file if it does not exist
-}
touch :: FilePath -> IO ()
touch file = do
    exists <- testfile file
    if exists
#ifdef mingw32_HOST_OS
        then do
            handle <- Win32.createFile
                (Filesystem.encodeString file)
                Win32.gENERIC_WRITE
                Win32.fILE_SHARE_NONE
                Nothing
                Win32.oPEN_EXISTING
                Win32.fILE_ATTRIBUTE_NORMAL
                Nothing
            (creationTime, _, _) <- Win32.getFileTime handle
            systemTime <- Win32.getSystemTimeAsFileTime
            Win32.setFileTime handle creationTime systemTime systemTime
#else
        then touchFile (Filesystem.encodeString file)
#endif
        else output file empty

{-| Time how long a command takes in monotonic wall clock time

    Returns the duration in seconds alongside the return value
-}
time :: IO a -> IO (a, NominalDiffTime)
time io = do
    TimeSpec seconds1 nanoseconds1 <- getTime Monotonic
    a <- io
    TimeSpec seconds2 nanoseconds2 <- getTime Monotonic
    let t = fromIntegral (    seconds2 -     seconds1)
          + fromIntegral (nanoseconds2 - nanoseconds1) / 10^(9::Int)
    return (a, fromRational t)

-- | Sleep for the given number of seconds
sleep :: Double -> IO ()
sleep n = threadDelay (truncate (n * 10^(6::Int)))

{-| Exit with the given exit code

    An exit code of @0@ indicates success
-}
exit :: Int -> IO ()
exit 0 = exitWith  ExitSuccess
exit n = exitWith (ExitFailure n)

-- | Print a message to standard error and exit with an exit code of @1@
die :: Text -> IO ()
die txt = do
    err txt
    exit 1

{-| Create a temporary directory underneath the given directory

    Deletes the temporary directory when done
-}
mktempdir
    :: FilePath
    -- ^ Parent directory
    -> Text
    -- ^ Directory name template
    -> Protected FilePath
mktempdir parent prefix = Protect (do
    dir' <- createTempDirectory
        (Filesystem.encodeString parent)
        (Text.unpack prefix)
    let dir = Filesystem.decodeString dir'
    return (dir, rmtree dir) )

{-| Create a temporary file underneath the given directory

    Deletes the temporary file when done
-}
mktemp
    :: FilePath
    -- ^ Parent directory
    -> Text
    -- ^ File name template
    -> Protected (FilePath, Handle)
mktemp parent prefix = Protect (do
    (file', handle) <- openTempFile
        (Filesystem.encodeString parent)
        (Text.unpack prefix)
    let file = Filesystem.decodeString file'
    return ((file, handle), rm file) )

-- | Fork a thread, acquiring an `Async` value
fork :: IO a -> Protected (Async a)
fork io = Protect (do
    a <- async io
    return (a, cancel a) )

-- | Read lines of `Text` from a `Handle`
handlein :: Handle -> Shell Text
handlein handle = Shell (\(FoldM step begin done) -> do
    x0 <- begin
    let loop x = do
            eof <- IO.hIsEOF handle
            if eof
                then done x
                else do
                    txt <- Text.hGetLine handle
                    x'  <- step x txt
                    loop $! x'
    loop $! x0 )

-- | Read lines of `Text` from standard input
stdin :: Shell Text
stdin = handlein IO.stdin

-- | Stream lines of `Text` to standard output
stdout :: Shell Text -> IO ()
stdout s = sh (do
    txt <- s
    liftIO (echo txt) )

-- | Stream lines of `Text` to standard error
stderr :: Shell Text -> IO ()
stderr s = sh (do
    txt <- s
    liftIO (err txt) )

-- | Read lines of `Text` from a file
input :: FilePath -> Shell Text
input file = do
    handle <- with (readhandle file)
    handlein handle

-- | Tee lines of `Text` to a file
output :: FilePath -> Shell Text -> IO ()
output file s = sh (do
    handle <- with (writehandle file)
    txt    <- s
    liftIO (Text.hPutStrLn handle txt) )

-- | Tee lines of `Text` to append to a file
append :: FilePath -> Shell Text -> IO ()
append file s = sh (do
    handle <- with (appendhandle file)
    txt    <- s
    liftIO (Text.hPutStrLn handle txt) )

-- | Acquire a `Protected` read-only `Handle` from a `FilePath`
readhandle :: FilePath -> Protected Handle
readhandle file = Protect (do
    handle <- Filesystem.openFile file IO.ReadMode
    return (handle, IO.hClose handle) )

-- | Acquire a `Protected` write-only `Handle` from a `FilePath`
writehandle :: FilePath -> Protected Handle
writehandle file = Protect (do
    handle <- Filesystem.openFile file IO.WriteMode
    return (handle, IO.hClose handle) )

-- | Acquire a `Protected` append-only `Handle` from a `FilePath`
appendhandle :: FilePath -> Protected Handle
appendhandle file = Protect (do
    handle <- Filesystem.openFile file IO.AppendMode
    return (handle, IO.hClose handle) )

-- | Combine the output of multiple `Shell`s, in order
cat :: [Shell a] -> Shell a
cat = msum

-- | Keep all lines that match the given `Pattern` anywhere within the line
grep :: Pattern a -> Shell Text -> Shell Text
grep pattern s = do
    txt <- s
    _:_ <- return (inside pattern txt)
    return txt

{-| Replace all occurrences of a `Pattern` with its `Text` result

    Warning: Do not use a `Pattern` that matches the empty string, since it will
    match an infinite number of times
-}
sed :: Pattern Text -> Shell Text -> Shell Text
sed pattern s = do
    let pattern' = fmap Text.concat
            (many (pattern <|> fmap Text.singleton anyChar))
    txt    <- s
    txt':_ <- return (match pattern' txt)
    return txt'

-- | Search a directory recursively for all files matching the given `Pattern`
find :: Pattern a -> FilePath -> Shell FilePath
find pattern dir = do
    path <- lstree dir
    Right txt <- return (Filesystem.toText path)
    _:_       <- return (inside pattern txt)
    return path

-- | A Stream of @\"y\"@s
yes :: Shell Text
yes = Shell (\(FoldM step begin _) -> do
    x0 <- begin
    let loop x = do
            x' <- step x "y"
            loop $! x'
    loop $! x0 )

-- | Limit a `Shell` to a fixed number of values
limit :: Int -> Shell a -> Shell a
limit n s = Shell (\(FoldM step begin done) -> do
    ref <- newIORef 0  -- I feel so dirty
    let step' x a = do
            n' <- readIORef ref
            writeIORef ref (n' + 1)
            if n' < n then step x a else return x
    foldIO s (FoldM step' begin done) )

{-| Limit a `Shell` to values that satisfy the predicate

    This terminates the stream on the first value that does not satisfy the
    predicate
-}
limitWhile :: (a -> Bool) -> Shell a -> Shell a
limitWhile predicate s = Shell (\(FoldM step begin done) -> do
    ref <- newIORef True
    let step' x a = do
            b <- readIORef ref
            let b' = b && predicate a
            writeIORef ref b'
            if b' then step x a else return x
    foldIO s (FoldM step' begin done) )

-- | Get the current time
date :: IO UTCTime
date = getCurrentTime

-- | Get the time a file was last modified
datefile :: FilePath -> IO UTCTime
datefile = Filesystem.getModified
