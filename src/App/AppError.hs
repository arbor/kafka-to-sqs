{-# LANGUAGE MultiParamTypeClasses #-}
module App.AppError
  ( module App.AppError
  , Control.Monad.Except.throwError
  ) where

import Control.Monad.Catch
import Control.Monad.Except
import Kafka.Avro
import Kafka.Types

data AppError = KafkaErr KafkaError
              | DecodeErr DecodeError
              | EncodeErr EncodeError
              | AppErr String
              deriving (Show, Eq)
instance Exception AppError

throwErrorAs :: MonadError e' m => (e -> e') -> Either e a -> m a
throwErrorAs f = either (throwError . f) pure

throwAs :: MonadThrow m => (e -> AppError) -> Either e a -> m a
throwAs f = either (throwM . f) pure

throwAs' :: MonadThrow m => (e -> AppError) -> Maybe e -> m ()
throwAs' f = maybe (pure ()) (throwM . f)
