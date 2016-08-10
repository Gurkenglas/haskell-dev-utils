{-# LANGUAGE BangPatterns, LambdaCase, OverloadedStrings, RecordWildCards #-}
{-# OPTIONS_GHC -Wall #-}
module Main (main) where

import Control.Applicative
import Control.Exception
import Control.Monad
import Data.Char
import Data.Functor
import Data.List
import Data.Monoid
import Data.Set (Set)
import Data.Text (Text)
import System.Directory
import System.Environment
import System.Exit
import System.IO (stderr, hPutStrLn)
import qualified Data.Attoparsec.Text as P
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T

(<&&>) :: (a -> Bool) -> (a -> Bool) -> (a -> Bool)
(<&&>) = liftA2 (&&)
infixr 3 <&&>

(<||>) :: (a -> Bool) -> (a -> Bool) -> (a -> Bool)
(<||>) = liftA2 (||)
infixr 2 <||>

parenthesize :: [T.Text] -> T.Text
parenthesize ss = "(" <> T.intercalate ", " ss <> ")"

----------------------------------------

data Symbols
  = NoSymbols
  | Explicit ![T.Text]
  | Hiding ![T.Text]
  deriving (Eq, Ord, Show)

parseSymbols :: P.Parser Symbols
parseSymbols = P.choice [
    Hiding   <$> (P.string "hiding" *> P.skipSpace *> parseSymbolList)
  , Explicit <$> parseSymbolList
  , return NoSymbols
  ]
  where
    parseSymbolList = do
      _ <- P.char '('
      P.skipSpace
      symbols <- (`P.sepBy` P.char ',') $ do
        P.skipSpace
        symbol <- P.choice [
            do -- operator
              _ <- P.char '('
              op <- P.takeWhile1 (/= ')')
              _ <- P.char ')'
              return $ "(" <> op <> ")"
          , P.takeWhile1 ((not . isSpace) <&&> (/= '(') <&&> (/= ')') <&&> (/= ','))
          ]
        P.skipSpace
        ctors <- P.option "" (parenthesize <$> parseSymbolList)
        P.skipSpace
        return $ symbol <> ctors
      P.skipSpace
      _ <- P.char ')'
      P.skipSpace
      return $ sort symbols

data Import = Import {
    imQualified      :: !Bool
  , imModule         :: !T.Text
  , imCaselessModule :: !T.Text
  , imAlias          :: !(Maybe T.Text)
  , imSymbols        :: !Symbols
  } deriving (Eq, Show)

compareImport :: Import -> Import -> Ordering
compareImport a b = mconcat [
    imQualified a      `compare` imQualified b
  , imCaselessModule a `compare` imCaselessModule b
  , imAlias a          `compare` imAlias b
  , imSymbols a        `compare` imSymbols b
  ]

parseImport :: P.Parser Import
parseImport = do
  _ <- P.string "import"
  P.skipSpace
  is_qualified <- P.option False (P.string "qualified" *> P.skipSpace $> True)
  module_ <- P.takeWhile1 $ (not . isSpace) <&&> (/= '(')
  P.skipSpace
  alias <- P.option Nothing (Just <$> parseAlias)
  P.skipSpace
  symbols <- parseSymbols
  return Import {
      imQualified      = is_qualified
    , imModule         = module_
    , imCaselessModule = T.toCaseFold module_
    , imAlias          = alias
    , imSymbols        = symbols
    }
  where
    parseAlias :: P.Parser T.Text
    parseAlias = do
      _ <- P.string "as"
      P.skipSpace
      alias <- P.takeWhile1 $ (not . isSpace) <&&> (/= '(')
      P.skipSpace
      return alias

showImport :: Import -> T.Text
showImport Import{..} = T.concat [
    "import"
  , if imQualified then " qualified" else ""
  , " "
  , imModule
  , maybe "" (" as " <>) imAlias
  , case imSymbols of
      NoSymbols   -> ""
      Explicit ss -> " " <> parenthesize ss
      Hiding ss   -> " hiding " <> parenthesize ss
  ]

----------------------------------------

-- | Transform the haskell source file by lexicographically sorting
-- all its imports and splitting them into two groups, foreign and
-- local ones.
convert :: Set Text -> Text -> Text
convert modules source = T.unlines . concat $ [
    reverse . dropWhile T.null $ reverse header
  , [T.empty]
  , map showImport foreign_imports
  , separator_if has_foreign_imports
  , map showImport local_imports
  , separator_if has_local_imports
  , rest
  ]
  where
    (header, body) = break is_import . T.lines $ source
    (import_section, rest) = break (not . (T.null <||> is_import)) body

    imports = case P.parseOnly (many parseImport) (T.unlines import_section) of
      Right imps -> sortBy compareImport imps
      Left  msg  -> error msg

    (local_imports, foreign_imports) = partition ((`S.member` modules) . imModule) imports

    is_import = T.isPrefixOf "import "

    has_foreign_imports = not $ null foreign_imports
    has_local_imports = not $ null local_imports

    separator_if p = if p then [T.empty] else []

-- | Recursively traverse the directory and pass all
-- haskell source files into accumulating function.
foldThroughHsFiles :: FilePath -> (acc -> FilePath -> IO acc) -> acc -> IO acc
foldThroughHsFiles basepath f iacc = do
  paths <- filter ((/= ".") <&&> (/= "..")) <$> getDirectoryContents basepath
  foldM run iacc paths
  where
    run acc path = do
      is_dir  <- doesDirectoryExist fullpath
      is_file <- doesFileExist fullpath
      case (is_file && (".hs" `isSuffixOf` path || ".lhs" `isSuffixOf` path), is_dir) of
        (True, False) -> f acc fullpath
        (False, True) -> foldThroughHsFiles fullpath f acc
        _             -> return acc
      where
        fullpath = basepath ++ "/" ++ path

-- | Collect modules and file paths from given directories.
inspectDirectories :: [FilePath] -> IO (Set Text, [FilePath])
inspectDirectories dirs = foldM (\acc dir -> do
  putStrLn $ "Inspecting " ++ dir ++ "..."
  foldThroughHsFiles dir (\(!modules, !files) file -> do
    let module_ = map slash_to_dot
                . drop (length dir + 1)  -- remove base directory (+ slash)
                . drop_extension
                $ file
    putStrLn $ "Found " ++ file ++ " (" ++ module_ ++ ")."
    return (S.insert (T.pack module_) modules, file : files)
    ) acc
  ) (S.empty, []) $ map remove_last_slash dirs
  where
    drop_extension = reverse . drop 1 . dropWhile (/= '.') . reverse

    slash_to_dot '/' = '.'
    slash_to_dot c = c

    remove_last_slash [] = []
    remove_last_slash ['/'] = []
    remove_last_slash (c:cs) = c : remove_last_slash cs

-- | Sort import lists in files at given locations.
sortImports :: String -> [FilePath] -> IO ()
sortImports suffix dirs = do
  (modules, files) <- inspectDirectories dirs
  -- transform files at collected locations
  forM_ files $ \file -> do
    putStr $ "Sorting imports in " ++ file ++ "..."
    T.readFile file
      >>= return . convert modules
      >>= T.writeFile (file ++ suffix)
    putStrLn " done."

-- | Check whether import lists in
-- files at given locations are sorted.
checkConsistency :: [FilePath] -> IO ()
checkConsistency dirs = do
  (modules, files) <- inspectDirectories dirs
  forM_ files $ \file -> do
    putStr $ "Checking whether imports in " ++ file ++ " are sorted..."
    source <- T.readFile file
    if source == convert modules source
      then putStrLn " yes."
      else do
        putStrLn " no."
        hPutStrLn stderr $ "Imports in " ++ file ++ " are not sorted"
        exitFailure

----------------------------------------

main :: IO ()
main = do
  (args, dirs) <- partition is_config_option <$> getArgs
  if null dirs
    then do
      prog <- getProgName
      putStrLn $ "Usage: " ++ prog ++ " [--check] [--suffix=SUFFIX] <directories>"
    else case get_options args of
      (False, suffix) -> sortImports suffix dirs
      (True, _) -> onException (checkConsistency dirs) $ do
        putStrLn $ "Run scripts/sort_imports.sh without --check option to fix the problem."
  where
    is_config_option = ("--" `isPrefixOf`)
    opt_suffix = "--suffix="
    opt_check  = "--check"

    get_options args = (check, suffix)
      where
        check = case find (== opt_check) args of
          Just _  -> True
          Nothing -> False
        suffix = case find (opt_suffix `isPrefixOf`) args of
          Just opt -> drop (length opt_suffix) opt
          Nothing  -> ""
