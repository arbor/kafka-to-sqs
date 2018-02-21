{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}

module App.Options.Cmd.SqsToKafka
  ( CmdSqsToKafka(..)
  , parserCmdSqsToKafka
  ) where

import App
import App.Kafka
import App.RunApplication
import App.SqsMessage
import Arbor.Logger
import Conduit
import Control.Arrow                        (left)
import Control.Error.Util
import Control.Lens
import Control.Monad.Except
import Data.Either.Combinators
import Data.Monoid
import HaskellWorks.Data.Conduit.Combinator
import Kafka.Avro
import Kafka.Conduit.Sink
import Network.AWS
import Network.AWS.SQS.DeleteMessageBatch
import Network.AWS.SQS.ReceiveMessage
import Network.AWS.SQS.Types
import Options.Applicative

import qualified Data.ByteString.Lazy as LBS
import qualified Data.Maybe           as DM (catMaybes)
import qualified Data.Text            as T

data CmdSqsToKafka = CmdSqsToKafka
  { _cmdSqsToKafkaInputSqsUrl :: String
  , _cmdSqsToKafkaOutputTopic :: TopicName
  , _cmdSqsToKafkaKafkaConfig :: KafkaConfig
  } deriving (Show, Eq)

makeLenses ''CmdSqsToKafka

instance HasKafkaConfig (GlobalOptions CmdSqsToKafka) where
  kafkaConfig = optCmd . cmdSqsToKafkaKafkaConfig

instance HasKafkaConfig (AppEnv CmdSqsToKafka) where
  kafkaConfig = appOptions . kafkaConfig

instance RunApplication CmdSqsToKafka where
  runApplication envApp = runApplicationM envApp $ do
    opt <- view appOptions
    kafkaConf <- view kafkaConfig

    let sqsUrl = opt ^. optCmd . cmdSqsToKafkaInputSqsUrl
    let kafkaTopic = opt ^. optCmd . cmdSqsToKafkaOutputTopic

    logInfo "Instantiating Schema Registry"
    sr <- schemaRegistry (kafkaConf ^. schemaRegistryAddress)

    logInfo "Creating Kafka Producer"
    producer <- mkProducer

    runConduit $
      receiveMessageC sqsUrl
      .| batchByOrFlush (BatchSize 10)
      .| effectC (handleMessages sr kafkaTopic producer)
      .| ackMessages sqsUrl
      .| sinkNull
    return ()

receiveMessageC :: MonadAWS m => String -> Source m (Maybe Message)
receiveMessageC sqsUrl = do
  let rm = receiveMessage (T.pack sqsUrl)
  rmr <- send (rm & (rmMaxNumberOfMessages .~ Just 10))
  case rmr ^.. rmrsMessages . each of
    []   -> yield Nothing
    msgs -> forM_ msgs $ yield . Just
  receiveMessageC sqsUrl

handleMessages :: (MonadIO m, MonadLogger m, MonadError AppError m) => SchemaRegistry -> TopicName -> KafkaProducer -> [Message] -> m ()
handleMessages sr t@(TopicName topic) producer msgs =
  forM_ msgs $ \msg -> do
    fcm <- decodeSqsMessage msg & note (AppErr "Unable to decode SQS message") & eitherToError
    payload <- encodeValue sr (Subject (T.pack topic)) fcm <&> left EncodeErr >>= eitherToError
    let p = ProducerRecord t UnassignedPartition Nothing (Just (LBS.toStrict payload))
    void $ produceMessage producer p
    logInfo $ "Produced record: " <> show p

ackMessages :: (Monad m, MonadAWS m) => String -> Conduit [Message] m ()
ackMessages sqsUrl =
  mapMC $ \msgs -> do
    let receipts = DM.catMaybes $ msgs ^.. each . mReceiptHandle
    -- each dmbr needs an ID. just use the list index.
    let dmbres = uncurry (\r i -> deleteMessageBatchRequestEntry (T.pack (show i)) r) <$> zip receipts [0..]
    void $ send $ deleteMessageBatch (T.pack sqsUrl) & dmbEntries .~ dmbres

parserCmdSqsToKafka :: Parser CmdSqsToKafka
parserCmdSqsToKafka = CmdSqsToKafka
  <$> strOption
    (  long "input-sqs-url"
    <> metavar "SQS_URL"
    <> help "Input SQS URL")
  <*> (TopicName <$>
    strOption
    (  long "output-topic-name"
    <> metavar "OUTPUT_TOPIC"
    <> help "Output kafka topic"))
  <*> kafkaConfigParser
