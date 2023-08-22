{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module ExpiringSpec where

import           Control.Monad.RWS.Strict (MonadWriter (tell), evalRWS, gets, modify)
import           Data.Foldable            (toList, traverse_)
import qualified Data.Map.Strict          as Map
import qualified Data.Map.Strict.Expiring as ExpiringMap
import           Data.Set                 (Set)
import qualified Data.Set                 as Set

import           Test.QuickCheck

newtype SomeKey = SomeKey Char
  deriving (Eq, Ord, Show)

instance Arbitrary SomeKey where
  arbitrary = SomeKey <$> elements ['a'..'e']

data MapOp = Insert SomeKey Int
           | Delete SomeKey
           | Lookup SomeKey
           | Update SomeKey Int
           | UpdateNothing SomeKey
  deriving Show

instance Arbitrary MapOp where
  arbitrary = oneof [Insert <$> arbitrary <*> arbitrary,
                     Delete <$> arbitrary,
                     Lookup <$> arbitrary,
                     Update <$> arbitrary <*> arbitrary,
                     UpdateNothing <$> arbitrary
                     ]

allOpTypes :: [String]
allOpTypes = ["Insert", "Delete", "Lookup", "Update", "UpdateNothing"]

prop_expMapDoesMapStuff :: [MapOp] -> Property
prop_expMapDoesMapStuff ops =
  coverTable "pkt types" ((,5) <$> allOpTypes) $
  tabulate "pkt types" (takeWhile (/= ' ') . show <$> ops) $
  checkCoverage $
  massocs === eassocs
  where
    massocs = snd $ evalRWS (applyOpsM ops) () (mempty :: Map.Map SomeKey Int)
    eassocs = snd $ evalRWS (applyOpsE ops) () (ExpiringMap.new 0)

    applyOpsM = traverse_ \case
      Insert k v -> do
        modify $ Map.insert k v
        tell =<< gets Map.assocs
      Delete k -> do
        modify $ Map.delete k
        tell =<< gets Map.assocs
      Lookup k -> do
        gets (Map.lookup k) >>= \case
          Nothing -> pure ()
          Just v  -> tell [(k, v)]
      Update k v -> do
        modify $ (snd <$> Map.updateLookupWithKey (\_ _ -> Just v) k)
        tell =<< gets Map.assocs
      UpdateNothing k -> do
        modify $ (snd <$> Map.updateLookupWithKey (\_ _ -> Nothing) k)
        tell =<< gets Map.assocs

    applyOpsE = traverse_ \case
      Insert k v -> do
        modify $ ExpiringMap.insert 1 k v
        tell =<< gets ExpiringMap.assocs
      Delete k -> do
        modify $ ExpiringMap.delete k
        tell =<< gets ExpiringMap.assocs
      Lookup k -> do
        gets (ExpiringMap.lookup k) >>= \case
          Nothing -> pure ()
          Just v  -> tell [(k, v)]
      Update k v -> do
        modify $ (snd <$> ExpiringMap.updateLookupWithKey 1 (\_ _ -> Just v) k)
        tell =<< gets ExpiringMap.assocs
      UpdateNothing k -> do
        modify $ (snd <$> ExpiringMap.updateLookupWithKey 1 (\_ _ -> Nothing) k)
        tell =<< gets ExpiringMap.assocs

prop_expiringMapWorks :: Int -> [Int] -> Property
prop_expiringMapWorks baseGen keys = Just keys === traverse (`ExpiringMap.lookup` m) keys
  where
    m = foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    futureGen = succ baseGen

ulength :: (Ord a, Foldable t) => t a -> Int
ulength = Set.size . Set.fromList . toList

prop_expiringMapExpires :: Int -> [Int] -> Property
prop_expiringMapExpires baseGen keys = (ulength keys, futureGen, ulength keys) === ExpiringMap.inspect m1 .&&. (0, lastGen, 0) === ExpiringMap.inspect m2
  where
    m1 = ExpiringMap.newGen futureGen $ foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    m2 = ExpiringMap.newGen lastGen m1
    futureGen = succ baseGen
    lastGen = succ futureGen

prop_expiringMapCannotAcceptExpired :: Positive Int -> Positive Int -> Int -> Property
prop_expiringMapCannotAcceptExpired (Positive lowGen) (Positive offset) k = ExpiringMap.inspect m === ExpiringMap.inspect m'
  where
    highGen = lowGen + offset
    m = ExpiringMap.new highGen :: ExpiringMap.Map Int Int Int
    m' = ExpiringMap.insert lowGen k k m

prop_expiringMapUpdateMissing :: Int -> Int -> Property
prop_expiringMapUpdateMissing gen k = mv === Nothing .&&. ExpiringMap.inspect m === ExpiringMap.inspect m'
  where
    m = ExpiringMap.new gen :: ExpiringMap.Map Int Int Bool
    (mv, m') = ExpiringMap.updateLookupWithKey gen (\_ _ -> Just True) k m

prop_expiringMapCannotUpdateExpired :: Positive Int -> Positive Int -> Int -> Property
prop_expiringMapCannotUpdateExpired (Positive lowGen) (Positive offset) k = mv === Nothing .&&. ExpiringMap.lookup k m' === Just True
  where
    highGen = lowGen + offset
    m = ExpiringMap.insert highGen k True $ ExpiringMap.new highGen
    (mv, m') = ExpiringMap.updateLookupWithKey lowGen (\_ _ -> Just False) k m

prop_expiringMapDelete :: Int -> [Int] -> Property
prop_expiringMapDelete baseGen keys = (ulength keys, baseGen, ulength keys) === ExpiringMap.inspect m .&&. (0, baseGen, 0) === ExpiringMap.inspect m'
  where
    m = foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    m' = foldr ExpiringMap.delete m keys
    futureGen = succ baseGen

prop_expiringMapElems :: Int -> Set Int -> Property
prop_expiringMapElems baseGen keys = keys === Set.fromList (toList m)
  where
    m = foldr (\x -> ExpiringMap.insert futureGen x x) (ExpiringMap.new baseGen) keys
    futureGen = succ baseGen

prop_expiringMapGen :: Int -> Int -> Property
prop_expiringMapGen g1 g2 = ExpiringMap.inspect m === (0, max g1 g2, 0)
  where
    m :: ExpiringMap.Map Int Int Int
    m = ExpiringMap.newGen g2 $ ExpiringMap.new g1