{-# LANGUAGE LambdaCase #-}
module Main where

import Arguments
import Control.Exception
import Data.Aeson
import Data.Aeson.Encode.Pretty
import Data.Map.Strict as Map
import qualified Data.ByteString.Lazy as DL
import qualified Data.ByteString.Char8 as DC
import Data.String
import qualified Data.Text as DT
import JSONTestCase
import qualified Prelude
import Prologue
import SemanticDiff (fetchDiffs)
import System.FilePath.Glob
import System.Process
import qualified Data.String.Utils as DSUtils
import Options.Applicative hiding ((<>))
import qualified Options.Applicative as O
import qualified Renderer as R

data GeneratorArgs = GeneratorArgs { generateResults :: Bool } deriving (Show)

generatorArgs :: Parser GeneratorArgs
generatorArgs = GeneratorArgs <$> switch ( long "generate-results" O.<> short 'g' O.<> help "Use generated expected results for new JSON test cases (rather than defaulting to an empty \"\")" )

options :: ParserInfo GeneratorArgs
options = info (helper <*> generatorArgs) (fullDesc O.<> progDesc "Auto-generate JSON test cases" O.<> header "JSON Test Case Generator")

main :: IO ()
main = do
  opts <- execParser options
  generatorFilePaths <- runFetchGeneratorFiles
  unparsedGeneratorCases <- traverse DL.readFile generatorFilePaths
  let parsedGeneratorCases = eitherDecode <$> unparsedGeneratorCases :: [Either String [JSONMetaRepo]]
  traverse_ (handleGeneratorCases opts generatorFilePaths) parsedGeneratorCases
  where handleGeneratorCases :: GeneratorArgs -> [FilePath] -> Either String [JSONMetaRepo] -> IO ()
        handleGeneratorCases opts generatorFilePaths parsedGeneratorCase =
          case parsedGeneratorCase of
            Left err ->  Prelude.putStrLn $ "An error occurred: " <> err
            Right metaTestCases -> do
              traverse_ (runGenerator opts) metaTestCases
              traverse_ runMoveGeneratorFile generatorFilePaths

-- | Finds all JSON files within the generators directory.
runFetchGeneratorFiles :: IO [FilePath]
runFetchGeneratorFiles = globDir1 (compile "*.json") "test/corpus/generators"

-- | First initialize the git submodule repository where commits will be made for the given metaRepo and its syntaxes.
-- | Second generate the commits for each syntax and generate the associated JSONTestCase objects.
-- | Finally push the generated commits to the submodule's remote repository.
runGenerator :: GeneratorArgs -> JSONMetaRepo -> IO ()
runGenerator opts metaRepo@JSONMetaRepo{..} = do
  runSetupGitRepo metaRepo
  runCommitsAndTestCasesGeneration opts metaRepo
  runUpdateGitRemote repoPath

-- | Upon successful test case generation for a generator file, move the file to the generated directory.
-- | This prevents subsequence runs of the test generator from duplicating test cases and adding extraneous
-- | commits to the git submodule.
runMoveGeneratorFile :: FilePath -> IO ()
runMoveGeneratorFile filePath = do
  let updatedPath = DT.unpack $ DT.replace (DT.pack "generators") (DT.pack "generated") (DT.pack filePath)
  Prelude.putStrLn updatedPath
  _ <- readCreateProcess (shell $ "mv " <> filePath <> " " <> updatedPath) ""
  return ()

-- | Initializes a new git repository and adds it as a submodule to the semantic-diff git index.
-- | This repository contains the commits associated with the given JSONMetaRepo's syntax examples.
runSetupGitRepo :: JSONMetaRepo -> IO ()
runSetupGitRepo JSONMetaRepo{..} = do
  runInitializeRepo repoUrl repoPath
  runAddSubmodule repoUrl repoPath

-- | Performs the system calls for initializing the git repository.
-- | If the git repository already exists, the operation will result in an error,
-- | but will not prevent successful completion of the test case generation.
runInitializeRepo :: String -> FilePath -> IO ()
runInitializeRepo repoUrl repoPath = do
  result <- try $ readCreateProcess (shell $ mkDirCommand repoPath) ""
  case (result :: Either Prelude.IOError String) of
    Left error -> Prelude.putStrLn $ "Creating the repository directory at " <> repoPath <> " failed with: " <> show error <> ". " <> "Possible reason: repository already initialized. \nProceeding to the next step."
    Right _ -> do
      _ <- executeCommand repoPath (initializeRepoCommand repoUrl)
      Prelude.putStrLn $ "Repository directory successfully initialized for " <> repoPath <> "."

-- | Git repositories generated as a side-effect of generating tests cases are
-- | added to semantic-diff's git index as submodules. If the submodule initialization
-- | fails (usually because the submodule was already initialized), operations will
-- | continue.
runAddSubmodule :: String -> FilePath -> IO ()
runAddSubmodule repoUrl repoPath = do
  result <- try $ readCreateProcess (shell $ addSubmoduleCommand repoUrl repoPath) ""
  case (result :: Either Prelude.IOError String) of
    Left error -> Prelude.putStrLn $ "Initializing the submodule repository at " <> repoPath <> " failed with: " <> show error <> ". " <> "Possible reason: submodule already initialized. \nProceeding to the next step."
    _ -> Prelude.putStrLn $ "Submodule successfully initialized for " <> repoPath <> "."

-- | Performs the system calls for generating the commits and test cases.
-- | Also appends the JSONTestCases generated to the test case file defined by
-- | the syntaxes.
runCommitsAndTestCasesGeneration :: GeneratorArgs -> JSONMetaRepo -> IO ()
runCommitsAndTestCasesGeneration opts JSONMetaRepo{..} =
  for_ syntaxes generate
    where generate :: JSONMetaSyntax -> IO ()
          generate metaSyntax = do
            _ <- runInitialCommitForSyntax repoPath metaSyntax
            runSetupTestCaseFile metaSyntax
            runCommitAndTestCaseGeneration opts language repoPath metaSyntax
            runCloseTestCaseFile metaSyntax

-- | For a syntax, we want the initial commit to be an empty file.
-- | This function performs a touch and commits the empty file.
runInitialCommitForSyntax :: FilePath -> JSONMetaSyntax -> IO ()
runInitialCommitForSyntax repoPath JSONMetaSyntax{..} = do
  Prelude.putStrLn $ "Generating initial commit for " <> syntax <> " syntax."
  result <- try . executeCommand repoPath $ touchCommand repoFilePath <> commitCommand syntax "Initial commit"
  case ( result :: Either Prelude.IOError String) of
    Left error -> Prelude.putStrLn $ "Initializing the " <> repoFilePath <> " failed with: " <> show error <> ". " <> "Possible reason: file already initialized. \nProceeding to the next step."
    Right _ -> pure ()

-- | Initializes the test case file where JSONTestCase examples are written to.
-- | This manually inserts a "[" to open a JSON array.
runSetupTestCaseFile :: JSONMetaSyntax -> IO ()
runSetupTestCaseFile metaSyntax = do
  Prelude.putStrLn $ "Opening " <> testCaseFilePath metaSyntax
  DL.writeFile (testCaseFilePath metaSyntax) "["

-- | For each command constructed for a given metaSyntax, execute the system commands.
runCommitAndTestCaseGeneration :: GeneratorArgs -> String -> FilePath -> JSONMetaSyntax -> IO ()
runCommitAndTestCaseGeneration opts language repoPath metaSyntax@JSONMetaSyntax{..} =
   traverse_ (runGenerateCommitAndTestCase opts language repoPath) (commands metaSyntax)

maybeMapSummary :: [R.Output] -> [Maybe (Map Text (Map Text [Value]))]
maybeMapSummary = fmap $ \case
    R.SummaryOutput output -> Just output
    _ -> Nothing

-- | This function represents the heart of the test case generation. It keeps track of
-- | the git shas prior to running a command, fetches the git sha after a command, so that
-- | JSONTestCase objects can be created. Finally, it appends the created JSONTestCase
-- | object to the test case file.
runGenerateCommitAndTestCase :: GeneratorArgs -> String -> FilePath -> (JSONMetaSyntax, String, String, String) -> IO ()
runGenerateCommitAndTestCase opts language repoPath (JSONMetaSyntax{..}, description, seperator, command) = do
  Prelude.putStrLn $ "Executing " <> syntax <> " " <> description <> " commit."
  beforeSha <- executeCommand repoPath getLastCommitShaCommand
  _ <- executeCommand repoPath command
  afterSha <- executeCommand repoPath getLastCommitShaCommand

  (summaryChanges, summaryErrors) <- runMaybeSummaries beforeSha afterSha repoPath repoFilePath opts

  let jsonTestCase = encodePretty JSONTestCase {
    gitDir = extractGitDir repoPath,
    testCaseDescription = language <> "-" <> syntax <> "-" <> description <> "-" <> "test",
    filePaths = [repoFilePath],
    sha1 = beforeSha,
    sha2 = afterSha,
    expectedResult = Map.fromList [
      ("changes", fromMaybe (Map.singleton mempty mempty) summaryChanges),
      ("errors", fromMaybe (Map.singleton mempty mempty) summaryErrors)
      ]
    }

  Prelude.putStrLn $ "Generating test case for " <> language <> ": " <> syntax <> " " <> description <> "."

  DL.appendFile testCaseFilePath $ jsonTestCase <> DL.fromStrict (DC.pack seperator)
  where extractGitDir :: String -> String
        extractGitDir fullRepoPath = DC.unpack $ snd $ DC.breakSubstring (DC.pack "test") (DC.pack fullRepoPath)

-- | Conditionally generate the diff summaries for the given shas and file path based
-- | on the -g | --generate flag. By default diff summaries are not generated when
-- | constructing test cases, and the tuple (Nothing, Nothing) is returned.
runMaybeSummaries :: String -> String -> FilePath -> FilePath -> GeneratorArgs -> IO (Maybe (Map Text [Value]), Maybe (Map Text [Value]))
runMaybeSummaries beforeSha afterSha repoPath repoFilePath GeneratorArgs{..}
  | generateResults = do
      diffs <- fetchDiffs $ args repoPath beforeSha afterSha [repoFilePath] R.Summary
      let headResult = Prelude.head $ maybeMapSummary diffs
      let changes = fromMaybe (fromList [("changes", mempty)]) headResult ! "changes"
      let errors = fromMaybe (fromList [("errors", mempty)]) headResult ! "errors"
      return (Just changes, Just errors)
  | otherwise = return (Nothing, Nothing)

-- | Commands represent the various combination of patches (insert, delete, replacement)
-- | for a given syntax.
commands :: JSONMetaSyntax -> [(JSONMetaSyntax, String, String, String)]
commands metaSyntax@JSONMetaSyntax{..} =
  [ (metaSyntax, "insert", commaSeperator, fileWriteCommand repoFilePath insert <> commitCommand syntax "insert")
  , (metaSyntax, "replacement-insert", commaSeperator, fileWriteCommand repoFilePath (Prologue.intercalate "\n" [replacement, insert, insert]) <> commitCommand syntax "replacement + insert + insert")
  , (metaSyntax, "delete-insert", commaSeperator, fileWriteCommand repoFilePath (Prologue.intercalate "\n" [insert, insert, insert]) <> commitCommand syntax "delete + insert")
  , (metaSyntax, "replacement", commaSeperator, fileWriteCommand repoFilePath (Prologue.intercalate "\n" [replacement, insert, insert]) <> commitCommand syntax "replacement")
  , (metaSyntax, "delete-replacement", commaSeperator, fileWriteCommand repoFilePath (Prologue.intercalate "\n" [insert, replacement]) <> commitCommand syntax "delete + replacement")
  , (metaSyntax, "delete", commaSeperator, fileWriteCommand repoFilePath replacement <> commitCommand syntax "delete")
  , (metaSyntax, "delete-rest", spaceSeperator, removeCommand repoFilePath <> touchCommand repoFilePath <> commitCommand syntax "delete rest")
  ]
  where commaSeperator = "\n,"
        spaceSeperator = ""

-- | Pushes git commits to the submodule repository's remote.
runUpdateGitRemote :: FilePath -> IO ()
runUpdateGitRemote repoPath = do
  Prelude.putStrLn "Updating git remote."
  _ <- executeCommand repoPath pushToGitRemoteCommand
  Prelude.putStrLn "Successfully updated git remote."

-- | Closes the JSON array and closes the test case file.
runCloseTestCaseFile :: JSONMetaSyntax -> IO ()
runCloseTestCaseFile metaSyntax = do
  Prelude.putStrLn $ "Closing " <> testCaseFilePath metaSyntax
  DL.appendFile (testCaseFilePath metaSyntax) "]\n"

initializeRepoCommand :: String -> String
initializeRepoCommand repoUrl = "rm -rf *; rm -rf .git; git init .; git remote add origin " <> repoUrl <> ";"

addSubmoduleCommand :: String -> FilePath -> String
addSubmoduleCommand repoUrl repoPath = "git submodule add " <> repoUrl <> " " <> " ./" <> repoPath <> ";"

getLastCommitShaCommand :: String
getLastCommitShaCommand = "git log --pretty=format:\"%H\" -n 1;"

touchCommand :: FilePath -> String
touchCommand repoFilePath = "touch " <> repoFilePath <> ";"

-- | In order to correctly record syntax examples that include backticks (like JavaScript template strings)
-- | we must first escape them for bash (due to the use of the `echo` system command). Additionally,
-- | we must also escape the escape character `\` in Haskell, hence the double `\\`.
fileWriteCommand :: FilePath -> String -> String
fileWriteCommand repoFilePath contents = "echo \"" <> (escapeBackticks . escapeDoubleQuotes) contents <> "\" > " <> repoFilePath <> ";"
  where
    escapeBackticks = DSUtils.replace "`" "\\`"
    escapeDoubleQuotes = DSUtils.replace "\"" "\\\""

commitCommand :: String -> String -> String
commitCommand syntax commitMessage = "git add .; git commit -m \"" <> syntax <> ": " <> commitMessage <> "\"" <> ";"

removeCommand :: FilePath -> String
removeCommand repoFilePath = "rm " <> repoFilePath <> ";"

pushToGitRemoteCommand :: String
pushToGitRemoteCommand = "git push origin HEAD;"

mkDirCommand :: FilePath -> String
mkDirCommand repoPath = "mkdir " <> repoPath <> ";"

executeCommand :: FilePath -> String -> IO String
executeCommand repoPath command = readCreateProcess (shell command) { cwd = Just repoPath } ""
