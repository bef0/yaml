{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}
module Data.Yaml.Internal
    (
      ParseException(..)
    , parse
    , decodeHelper
    ) where

import qualified Text.Libyaml as Y
import Data.Aeson
import Data.Aeson.Types hiding (parse)
import Text.Libyaml hiding (encode, decode, encodeFile, decodeFile)
import Data.ByteString (ByteString)
import qualified Data.Map as Map
import Control.Exception
import Control.Monad.Trans.State
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import Control.Monad.Trans.Class (MonadTrans, lift)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad (liftM, ap)
import Control.Applicative (Applicative(..))
import Data.Char (toUpper)
import qualified Data.Vector as V
import Data.Text (Text, pack)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import qualified Data.HashMap.Strict as M
import Data.Typeable
import Data.Text.Read
#if MIN_VERSION_aeson(0, 7, 0)
import Data.Scientific (fromFloatDigits)
#else
import Data.Attoparsec.Number
#endif
import Control.Monad.Trans.Resource (ResourceT, runResourceT)

data ParseException = NonScalarKey
                    | UnknownAlias { _anchorName :: Y.AnchorName }
                    | UnexpectedEvent { _received :: Maybe Event
                                      , _expected :: Maybe Event
                                      }
                    | InvalidYaml (Maybe YamlException)
                    | AesonException String
                    | OtherParseException SomeException
                    | NonStringKeyAlias Y.AnchorName Value
                    | CyclicIncludes
    deriving (Show, Typeable)
instance Exception ParseException

newtype PErrorT m a = PErrorT { runPErrorT :: m (Either ParseException a) }
instance Monad m => Functor (PErrorT m) where
    fmap = liftM
instance Monad m => Applicative (PErrorT m) where
    pure  = return
    (<*>) = ap
instance Monad m => Monad (PErrorT m) where
    return = PErrorT . return . Right
    (PErrorT m) >>= f = PErrorT $ do
        e <- m
        case e of
            Left e' -> return $ Left e'
            Right a -> runPErrorT $ f a
instance MonadTrans PErrorT where
    lift = PErrorT . liftM Right
instance MonadIO m => MonadIO (PErrorT m) where
    liftIO = lift . liftIO

type Parse = StateT (Map.Map String Value) (ResourceT IO)

requireEvent :: Event -> C.Sink Event Parse ()
requireEvent e = do
    f <- CL.head
    if f == Just e
        then return ()
        else liftIO $ throwIO $ UnexpectedEvent f $ Just e

parse :: C.Sink Event Parse Value
parse = do
    requireEvent EventStreamStart
    requireEvent EventDocumentStart
    res <- parseO
    requireEvent EventDocumentEnd
    requireEvent EventStreamEnd
    return res

parseScalar :: ByteString -> Anchor -> Style -> Tag
            -> C.Sink Event Parse Text
parseScalar v a style tag = do
    let res = decodeUtf8With lenientDecode v
    case a of
        Nothing -> return res
        Just an -> do
            lift $ modify (Map.insert an $ textToValue style tag res)
            return res

textToValue :: Style -> Tag -> Text -> Value
textToValue SingleQuoted _ t = String t
textToValue DoubleQuoted _ t = String t
textToValue _ StrTag t = String t
textToValue Folded _ t = String t
textToValue _ _ t
    | t `elem` ["null", "Null", "NULL", "~", ""] = Null
    | any (t `isLike`) ["y", "yes", "on", "true"] = Bool True
    | any (t `isLike`) ["n", "no", "off", "false"] = Bool False
#if MIN_VERSION_aeson(0, 7, 0)
    | Right (x, "") <- signed decimal t = Number $ fromIntegral (x :: Integer)
    | Right (x, "") <- double t = Number $ fromFloatDigits x
#else
    | Right (x, "") <- signed decimal t = Number $ I x
    | Right (x, "") <- double t = Number $ D x
#endif
    | otherwise = String t
  where x `isLike` ref = x `elem` [ref, T.toUpper ref, titleCased]
          where titleCased = toUpper (T.head ref) `T.cons` T.tail ref


parseO :: C.Sink Event Parse Value
parseO = do
    me <- CL.head
    case me of
        Just (EventScalar v tag style a) -> fmap (textToValue style tag) $ parseScalar v a style tag
        Just (EventSequenceStart a) -> parseS a id
        Just (EventMappingStart a) -> parseM a M.empty
        Just (EventAlias an) -> do
            m <- lift get
            case Map.lookup an m of
                Nothing -> liftIO $ throwIO $ UnknownAlias an
                Just v -> return v
        _ -> liftIO $ throwIO $ UnexpectedEvent me Nothing

parseS :: Y.Anchor
       -> ([Value] -> [Value])
       -> C.Sink Event Parse Value
parseS a front = do
    me <- CL.peek
    case me of
        Just EventSequenceEnd -> do
            CL.drop 1
            let res = Array $ V.fromList $ front []
            case a of
                Nothing -> return res
                Just an -> do
                    lift $ modify $ Map.insert an res
                    return res
        _ -> do
            o <- parseO
            parseS a $ front . (:) o

parseM :: Y.Anchor
       -> M.HashMap Text Value
       -> C.Sink Event Parse Value
parseM a front = do
    me <- CL.peek
    case me of
        Just EventMappingEnd -> do
            CL.drop 1
            let res = Object front
            case a of
                Nothing -> return res
                Just an -> do
                    lift $ modify $ Map.insert an res
                    return res
        _ -> do
            CL.drop 1
            s <- case me of
                    Just (EventScalar v tag style a') -> parseScalar v a' style tag
                    Just (EventAlias an) -> do
                        m <- lift get
                        case Map.lookup an m of
                            Nothing -> liftIO $ throwIO $ UnknownAlias an
                            Just (String t) -> return t
                            Just v -> liftIO $ throwIO $ NonStringKeyAlias an v
                    _ -> liftIO $ throwIO $ UnexpectedEvent me Nothing
            o <- parseO

            let al  = M.insert s o front
                al' = if s == pack "<<"
                         then case o of
                                  Object l  -> M.union front l
                                  Array l -> M.union front $ foldl merge' M.empty $ V.toList l
                                  _          -> al
                         else al
            parseM a al'
    where merge' al (Object om) = M.union al om
          merge' al _           = al

decodeHelper :: FromJSON a
             => C.Source Parse Y.Event
             -> IO (Either ParseException (Either String a))
decodeHelper src = do
    x <- try $ runResourceT $ flip evalStateT Map.empty $ src C.$$ parse
    case x of
        Left e
            | Just pe <- fromException e -> return $ Left pe
            | Just ye <- fromException e -> return $ Left $ InvalidYaml $ Just (ye :: YamlException)
            | otherwise -> throwIO e
        Right y -> return $ Right $ parseEither parseJSON y
