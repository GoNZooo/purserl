{-# LANGUAGE TypeApplications #-}
module Language.PureScript.Make.BuildPlan
  ( BuildPlan(bpEnv)
  , BuildJobResult(..)
  , WasRebuildNeeded(..)
  , buildJobSucceeded
  , buildJobSuccess
  , construct
  , getResult
  , collectResults
  , markComplete
  , needsRebuild
  --
  , bjResult
  , bpBuildJobs
  , pbExternsFile
  , bpPrebuilt
  , getDirtyCacheFile
  , bjPrebuilt
  , bjDirtyExterns
  , isCacheHit
  ) where

import           Prelude

import Codec.Serialise as Serialise
import           Control.Concurrent.Async.Lifted as A
import           Control.Concurrent.Lifted as C
import           Control.Monad.Base (liftBase)
import           Control.Monad hiding (sequence)
import           Control.Monad.Trans.Control (MonadBaseControl(..))
import           Control.Monad.Trans.Maybe (MaybeT(..), runMaybeT)
import           Data.Foldable (foldl')
import qualified Data.List as L
import qualified Data.Map as M
import           Data.Maybe (fromMaybe, mapMaybe)
import           Data.Time.Clock (UTCTime(..))
import           Data.Time.Calendar.OrdinalDate (fromOrdinalDate)
import           Language.PureScript.AST
import           Language.PureScript.Crash
import qualified Language.PureScript.CST as CST
import           Language.PureScript.Errors
import           Language.PureScript.Externs
import           Language.PureScript.Make.Actions as Actions
import           Language.PureScript.Make.Cache
import           Language.PureScript.Names (ModuleName(..))
import           Language.PureScript.Sugar.Names.Env
import           System.Directory (getCurrentDirectory)
import Data.Function
import Data.Functor
import Debug.Trace
import qualified Data.ByteString.Lazy as B

-- for debug prints, timestamps
import Language.PureScript.Docs.Types (formatTime)
import Data.Time.Clock (getCurrentTime)
import System.IO.Unsafe (unsafePerformIO)

{-# NOINLINE dt #-}
dt = do
  ts <- getCurrentTime
  pure (formatTime ts)


-- | The BuildPlan tracks information about our build progress, and holds all
-- prebuilt modules for incremental builds.
data BuildPlan = BuildPlan
  { bpPrebuilt :: M.Map ModuleName Prebuilt
  , bpBuildJobs :: M.Map ModuleName BuildJob
  , bpEnv :: C.MVar Env
  }

data Prebuilt = Prebuilt
  { pbModificationTime :: UTCTime
  , pbExternsFile :: ExternsFile
  }

data BuildJob = BuildJob
  { bjResult :: C.MVar BuildJobResult
    -- ^ Note: an empty MVar indicates that the build job has not yet finished.
    -- TODO[drathier]: remove both fields here:
  , bjPrebuilt :: Maybe Prebuilt
  , bjDirtyExterns :: Maybe ExternsFile
  }

data BuildJobResult
  = BuildJobSucceeded !MultipleErrors !ExternsFile !WasRebuildNeeded
  -- ^ Succeeded, with warnings and externs
  --
  | BuildJobCacheHit !ExternsFile
  -- ^ Cache hit, so no warnings
  --
  | BuildJobFailed !MultipleErrors
  -- ^ Failed, with errors

  | BuildJobSkipped
  -- ^ The build job was not run, because an upstream build job failed

data WasRebuildNeeded
  = RebuildWasNeeded
  | RebuildWasNotNeeded
  deriving (Show, Eq)

buildJobSucceeded :: Maybe ExternsFile -> MultipleErrors -> ExternsFile -> BuildJobResult
buildJobSucceeded mDirtyExterns warnings externs =
  case mDirtyExterns of
    Just dirtyExterns | fastEqExterns dirtyExterns externs -> BuildJobSucceeded warnings externs RebuildWasNotNeeded
    _ -> BuildJobSucceeded warnings externs RebuildWasNeeded

fastEqExterns a b =
  let
    -- TODO[drathier]: is it enough to look at just the cacheDeclarations (what we export)? or do we need to look at the cached imports too?
    toCmp x = bcCacheDeclarations $ efBuildCache x
  in
  Serialise.serialise (toCmp a) == Serialise.serialise (toCmp b)

buildJobSuccess :: BuildJobResult -> Maybe (MultipleErrors, ExternsFile, WasRebuildNeeded)
buildJobSuccess (BuildJobSucceeded warnings externs wasRebuildNeeded) = Just (warnings, externs, wasRebuildNeeded)
buildJobSuccess (BuildJobCacheHit externs) = Just (MultipleErrors [], externs, RebuildWasNotNeeded)
buildJobSuccess _ = Nothing



isCacheHit
  :: MonadBaseControl IO m
  => M.Map ModuleName (MVar BuildJobResult)
  -> M.Map ModuleName ()
  -> M.Map ModuleName ExternsFile
  -> ExternsFile
  -> m Bool
isCacheHit deps directDeps depsExternsFromPrebuilts dirtyExterns = do
  -- did any dependency change? if not, early return
  noUpstreamChanges <-
    deps
      -- & (\v -> trace (show ("depsExternDecls1" :: String, M.keys v)) v)
      & (id :: M.Map ModuleName (MVar BuildJobResult) -> M.Map ModuleName (MVar BuildJobResult))
      & (\keepValues -> M.intersection keepValues directDeps)
      -- & (\v -> trace (show ("depsExternDecls2" :: String, M.keys v, "dirtyImportedModules" :: String, dirtyImportedModules)) v)
      & (id :: M.Map ModuleName (MVar BuildJobResult) -> M.Map ModuleName (MVar BuildJobResult))
      & traverse tryReadMVar
      & fmap (\bjmap ->
        bjmap
        & M.elems
        & fmap (fromMaybe (internalError "isCacheHit1: no barrier"))
        & all (\case
          BuildJobSucceeded _ _ RebuildWasNotNeeded -> True
          BuildJobCacheHit _ -> True
          _ -> False
        )
      )
  pure noUpstreamChanges

-- | Information obtained about a particular module while constructing a build
-- plan; used to decide whether a module needs rebuilding.
data RebuildStatus = RebuildStatus
  { statusModuleName :: ModuleName
  , statusRebuildNever :: Bool
  , statusNewCacheInfo :: Maybe CacheInfo
    -- ^ New cache info for this module which should be stored for subsequent
    -- incremental builds. A value of Nothing indicates that cache info for
    -- this module should not be stored in the build cache, because it is being
    -- rebuilt according to a RebuildPolicy instead.
  , statusPrebuilt :: Maybe Prebuilt
    -- ^ Prebuilt externs and timestamp for this module, if any.
  , statusDirtyExterns :: Maybe ExternsFile
    -- ^ Prebuilt externs and timestamp for this module, if any, but also present even if the source file is changed.
  }

-- | Called when we finished compiling a module and want to report back the
-- compilation result, as well as any potential errors that were thrown.
markComplete
  :: (MonadBaseControl IO m)
  => BuildPlan
  -> ModuleName
  -> BuildJobResult
  -> m ()
markComplete buildPlan moduleName result = do
  let BuildJob rVar _ _ = fromMaybe (internalError "make: markComplete no barrier") $ M.lookup moduleName (bpBuildJobs buildPlan)
  putMVar rVar result

-- | Whether or not the module with the given ModuleName needs to be rebuilt
needsRebuild :: BuildPlan -> ModuleName -> Bool
needsRebuild bp moduleName = M.member moduleName (bpBuildJobs bp)

-- | Collects results for all prebuilt as well as rebuilt modules. This will
-- block until all build jobs are finished. Prebuilt modules always return no
-- warnings.
collectResults
  :: (MonadBaseControl IO m)
  => BuildPlan
  -> m (M.Map ModuleName BuildJobResult)
collectResults buildPlan = do
  let prebuiltResults = M.map (buildJobSucceeded Nothing (MultipleErrors []) . pbExternsFile) (bpPrebuilt buildPlan)
  barrierResults <- traverse (readMVar . bjResult) $ bpBuildJobs buildPlan
  pure (M.union prebuiltResults barrierResults)

-- | Gets the the build result for a given module name independent of whether it
-- was rebuilt or prebuilt. Prebuilt modules always return no warnings.
getResult
  :: (MonadBaseControl IO m)
  => BuildPlan
  -> ModuleName
  -> m (Maybe (MultipleErrors, ExternsFile, WasRebuildNeeded))
getResult buildPlan moduleName =
  case M.lookup moduleName (bpPrebuilt buildPlan) of
    Just es ->
      pure (Just (MultipleErrors [], pbExternsFile es, RebuildWasNotNeeded))
    Nothing -> do
      let bj = fromMaybe (internalError "make: no barrier") $ M.lookup moduleName (bpBuildJobs buildPlan)
      r <- readMVar $ bjResult bj
      pure $ buildJobSuccess r

-- | Gets the Prebuilt for any modules whose source files didn't change.
didModuleSourceFilesChange
  :: BuildPlan
  -> ModuleName
  -> Maybe Prebuilt
didModuleSourceFilesChange buildPlan moduleName =
  bjPrebuilt =<< M.lookup moduleName (bpBuildJobs buildPlan)

-- | Gets the Prebuilt for any modules whose source files didn't change.
getDirtyCacheFile
  :: BuildPlan
  -> ModuleName
  -> Maybe ExternsFile
getDirtyCacheFile buildPlan moduleName =
  bjDirtyExterns =<< M.lookup moduleName (bpBuildJobs buildPlan)

-- | Constructs a BuildPlan for the given module graph.
--
-- The given MakeActions are used to collect various timestamps in order to
-- determine whether a module needs rebuilding.
construct
  :: forall m. (Monad m, MonadBaseControl IO m)
  => MakeActions m
  -> CacheDb
  -> ([CST.PartialResult Module], [(ModuleName, [ModuleName])])
  -> m (BuildPlan, CacheDb)
construct MakeActions{..} cacheDb (sorted, graph) = do
  let sortedModuleNames = map (getModuleName . CST.resPartial) sorted
  rebuildStatuses <- A.forConcurrently sortedModuleNames getRebuildStatus
  let prebuilt =
        foldl' collectPrebuiltModules M.empty $
          mapMaybe (\s -> (statusModuleName s, statusRebuildNever s,) <$> statusPrebuilt s) (snd <$> rebuildStatuses)
  let toBeRebuilt = filter (not . flip M.member prebuilt . fst) rebuildStatuses
  -- _ <- trace (show ("BuildPlan.construct 4 start" :: String, unsafePerformIO dt)) $ pure ()
  buildJobs <- foldM makeBuildJob M.empty toBeRebuilt
  -- _ <- trace (show ("BuildPlan.construct 5 start" :: String, unsafePerformIO dt)) $ pure ()
  env <- C.newMVar primEnv
  -- _ <- trace (show ("BuildPlan.construct 6 start" :: String, unsafePerformIO dt)) $ pure ()
  let res =
        ( BuildPlan prebuilt buildJobs env
        , let
            update = flip $ \s ->
              M.alter (const (statusNewCacheInfo s)) (statusModuleName s)
          in
            foldl' update cacheDb (snd <$> rebuildStatuses)
        )
  -- trace (show ("BuildPlan.construct 7 end" :: String, unsafePerformIO dt)) $ pure ()
  pure res
  where
    makeBuildJob prev (moduleName, rebuildStatus) = do
      buildJobMvar <- C.newEmptyMVar
      let buildJob = BuildJob buildJobMvar (statusPrebuilt rebuildStatus) (statusDirtyExterns rebuildStatus)
      pure (M.insert moduleName buildJob prev)

    getRebuildStatus :: ModuleName -> m (ModuleName, RebuildStatus)
    -- TODO[drathier]: statusDirtyExterns seemingly contains no more info than Prebuilt does; are we filtering Prebuilt but not DirtyExterns somewhere? Why have both?
    getRebuildStatus moduleName = (moduleName,) <$> do
      inputInfo <- getInputTimestampsAndHashes moduleName
      case inputInfo of
        Left RebuildNever -> do
          dirtyExterns <- snd <$> readExterns moduleName
          prebuilt <- findExistingExtern dirtyExterns moduleName
          pure (RebuildStatus
            { statusModuleName = moduleName
            , statusRebuildNever = True
            , statusPrebuilt = prebuilt
            , statusDirtyExterns = dirtyExterns
            , statusNewCacheInfo = Nothing
            })
        Left RebuildAlways -> do
          pure (RebuildStatus
            { statusModuleName = moduleName
            , statusRebuildNever = False
            , statusPrebuilt = Nothing
            , statusDirtyExterns = Nothing
            , statusNewCacheInfo = Nothing
            })
        Right cacheInfo -> do
          cwd <- liftBase getCurrentDirectory
          (newCacheInfo, isUpToDate) <- checkChanged cacheDb moduleName cwd cacheInfo
          dirtyExterns <- snd <$> readExterns moduleName
          prebuilt <-
            -- NOTE[fh]: prebuilt is Nothing for source-modified files, and Just for non-source modified files
            if isUpToDate
              then findExistingExtern dirtyExterns moduleName
              else pure Nothing
          pure (RebuildStatus
            { statusModuleName = moduleName
            , statusRebuildNever = False
            , statusPrebuilt = prebuilt
            , statusDirtyExterns = dirtyExterns
            , statusNewCacheInfo = Just newCacheInfo
            })

    findExistingExtern :: Maybe ExternsFile -> ModuleName -> m (Maybe Prebuilt)
    findExistingExtern mexterns moduleName = runMaybeT $ do
      timestamp <- MaybeT $ getOutputTimestamp moduleName
      externs <- MaybeT $ pure mexterns
      pure (Prebuilt timestamp externs)

    collectPrebuiltModules :: M.Map ModuleName Prebuilt -> (ModuleName, Bool, Prebuilt) -> M.Map ModuleName Prebuilt
    collectPrebuiltModules prev (moduleName, rebuildNever, pb)
      | rebuildNever = M.insert moduleName pb prev
      | otherwise = do
          let deps = fromMaybe (internalError "make: module not found in dependency graph.") (lookup moduleName graph)
          case traverse (fmap pbModificationTime . flip M.lookup prev) deps of
            Nothing ->
              -- If we end up here, one of the dependencies didn't exist in the
              -- prebuilt map and so we know a dependency might need to be rebuilt, which
              -- means we might need to be rebuilt in turn.
              prev
            Just modTimes ->
              -- TODO[drathier]: this feels too pessimistic, we might not have to rebuild even if a dep was modified; is this code intended to just filter out things we for sure won't have to rebuild, or to exactly say which files we should rebuild?
              case maximumMaybe modTimes of
                Just depModTime | pbModificationTime pb < depModTime ->
                  prev
                _ -> M.insert moduleName pb prev

maximumMaybe :: Ord a => [a] -> Maybe a
maximumMaybe [] = Nothing
maximumMaybe xs = Just $ maximum xs
