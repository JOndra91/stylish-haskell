--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
module Language.Haskell.Stylish.Config
    ( Extensions
    , Config (..)
    , defaultConfigFilePath
    , configFilePath
    , loadConfig
    ) where


--------------------------------------------------------------------------------
import           Control.Monad                                    (forM, mzero)
import           Data.Aeson                                       (FromJSON (..))
import qualified Data.Aeson                                       as A
import qualified Data.Aeson.Types                                 as A
import qualified Data.ByteString                                  as B
import           Data.List                                        (inits,
                                                                   intercalate)
import           Data.Map                                         (Map)
import qualified Data.Map                                         as M
import           Data.Yaml                                        (decodeEither)
import           System.Directory
import           System.FilePath                                  (joinPath,
                                                                   splitPath,
                                                                   (</>))


--------------------------------------------------------------------------------
import           Language.Haskell.Stylish.Step
import qualified Language.Haskell.Stylish.Step.Imports            as Imports
import qualified Language.Haskell.Stylish.Step.LanguagePragmas    as LanguagePragmas
import qualified Language.Haskell.Stylish.Step.Records            as Records
import qualified Language.Haskell.Stylish.Step.Tabs               as Tabs
import qualified Language.Haskell.Stylish.Step.TrailingWhitespace as TrailingWhitespace
import qualified Language.Haskell.Stylish.Step.UnicodeSyntax      as UnicodeSyntax
import           Language.Haskell.Stylish.Verbose
import           Paths_stylish_haskell                            (getDataFileName)


--------------------------------------------------------------------------------
type Extensions = [String]


--------------------------------------------------------------------------------
data Config = Config
    { configSteps              :: [Step]
    , configColumns            :: Int
    , configLanguageExtensions :: [String]
    }


--------------------------------------------------------------------------------
instance FromJSON Config where
    parseJSON = parseConfig


--------------------------------------------------------------------------------
emptyConfig :: Config
emptyConfig = Config [] 80 []


--------------------------------------------------------------------------------
configFileName :: String
configFileName = ".stylish-haskell.yaml"


--------------------------------------------------------------------------------
defaultConfigFilePath :: IO FilePath
defaultConfigFilePath = getDataFileName "data/stylish-haskell.yaml"


--------------------------------------------------------------------------------
configFilePath :: Verbose -> Maybe FilePath -> IO (Maybe FilePath)
configFilePath _       (Just userSpecified) = return $ Just userSpecified
configFilePath verbose Nothing              = do
    current <- getCurrentDirectory
    home    <- getHomeDirectory
    def     <- defaultConfigFilePath
    search $
        [d </> configFileName | d <- ancestors current] ++
        [home </> configFileName, def]
  where
    -- All ancestors of a dir (including that dir)
    ancestors :: FilePath -> [FilePath]
    ancestors = init . map joinPath . reverse . inits . splitPath

    search :: [FilePath] -> IO (Maybe FilePath)
    search []       = return Nothing
    search (f : fs) = do
        -- TODO Maybe catch an error here, dir might be unreadable
        exists <- doesFileExist f
        verbose $ f ++ if exists then " exists" else " does not exist"
        if exists then return (Just f) else search fs


--------------------------------------------------------------------------------
loadConfig :: Verbose -> Maybe FilePath -> IO Config
loadConfig verbose mfp = do
    mfp' <- configFilePath verbose mfp
    case mfp' of
        Nothing -> do
            verbose $ "Using empty configuration"
            return emptyConfig
        Just fp -> do
            verbose $ "Loading configuration at " ++ fp
            bs <- B.readFile fp
            case decodeEither bs of
                Left err     -> error $
                    "Language.Haskell.Stylish.Config.loadConfig: " ++ err
                Right config -> return config


--------------------------------------------------------------------------------
parseConfig :: A.Value -> A.Parser Config
parseConfig (A.Object o) = do
    -- First load the config without the actual steps
    config <- Config
        <$> pure []
        <*> (o A..:? "columns"             A..!= 80)
        <*> (o A..:? "language_extensions" A..!= [])

    -- Then fill in the steps based on the partial config we already have
    stepValues <- o A..: "steps" :: A.Parser [A.Value]
    steps      <- mapM (parseSteps config) stepValues
    return config {configSteps = concat steps}
parseConfig _            = mzero


--------------------------------------------------------------------------------
catalog :: Map String (Config -> A.Object -> A.Parser Step)
catalog = M.fromList
    [ ("imports",             parseImports)
    , ("language_pragmas",    parseLanguagePragmas)
    , ("records",             parseRecords)
    , ("tabs",                parseTabs)
    , ("trailing_whitespace", parseTrailingWhitespace)
    , ("unicode_syntax",      parseUnicodeSyntax)
    ]


--------------------------------------------------------------------------------
parseSteps :: Config -> A.Value -> A.Parser [Step]
parseSteps config val = do
    map' <- parseJSON val :: A.Parser (Map String A.Value)
    forM (M.toList map') $ \(k, v) -> case (M.lookup k catalog, v) of
        (Just parser, A.Object o) -> parser config o
        _                         -> fail $ "Invalid declaration for " ++ k


--------------------------------------------------------------------------------
-- | Utility for enum-like options
parseEnum :: [(String, a)] -> a -> Maybe String -> A.Parser a
parseEnum _    def Nothing  = return def
parseEnum strs _   (Just k) = case lookup k strs of
    Just v  -> return v
    Nothing -> fail $ "Unknown option: " ++ k ++ ", should be one of: " ++
        intercalate ", " (map fst strs)


--------------------------------------------------------------------------------
parseImports :: Config -> A.Object -> A.Parser Step
parseImports config o = Imports.step
    <$> pure (configColumns config)
    <*> (Imports.Align
        <$> (o A..:? "align" >>= parseEnum aligns Imports.Global)
        <*> (o A..:? "list_align" >>= parseEnum listAligns Imports.AfterAlias)
        <*> (o A..:? "long_list_align"
            >>= parseEnum longListAligns Imports.Inline)
        <*> (maybe 4 (max 1) <$> o A..:? "list_padding")
            -- ^ Padding have to be at least 1. Default is 4.
        <*> o A..:? "separate_lists" A..!= True)
  where
    aligns =
        [ ("global", Imports.Global)
        , ("file",   Imports.File)
        , ("group",  Imports.Group)
        , ("none",   Imports.None)
        ]

    listAligns =
        [ ("new_line",    Imports.NewLine)
        , ("with_alias",  Imports.WithAlias)
        , ("after_alias", Imports.AfterAlias)
        ]

    longListAligns =
        [ ("inline",             Imports.Inline)
        , ("new_line",           Imports.InlineWithBreak)
        , ("new_line_multiline", Imports.InlineToMultiline)
        , ("multiline",          Imports.Multiline)
        ]


--------------------------------------------------------------------------------
parseLanguagePragmas :: Config -> A.Object -> A.Parser Step
parseLanguagePragmas config o = LanguagePragmas.step
    <$> pure (configColumns config)
    <*> (o A..:? "style" >>= parseEnum styles LanguagePragmas.Vertical)
    <*> o A..:? "align" A..!= True
    <*> o A..:? "remove_redundant" A..!= True
  where
    styles =
        [ ("vertical",     LanguagePragmas.Vertical)
        , ("compact",      LanguagePragmas.Compact)
        , ("compact_line", LanguagePragmas.CompactLine)
        ]


--------------------------------------------------------------------------------
parseRecords :: Config -> A.Object -> A.Parser Step
parseRecords _ _ = return Records.step


--------------------------------------------------------------------------------
parseTabs :: Config -> A.Object -> A.Parser Step
parseTabs _ o = Tabs.step
    <$> o A..:? "spaces" A..!= 8


--------------------------------------------------------------------------------
parseTrailingWhitespace :: Config -> A.Object -> A.Parser Step
parseTrailingWhitespace _ _ = return TrailingWhitespace.step


--------------------------------------------------------------------------------
parseUnicodeSyntax :: Config -> A.Object -> A.Parser Step
parseUnicodeSyntax _ o = UnicodeSyntax.step
    <$> o A..:? "add_language_pragma" A..!= True
