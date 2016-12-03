{-# LANGUAGE BangPatterns, OverloadedStrings #-}

module Hakase.Client
    ( -- * Simple interface
      hakase
    , hakaseM
      -- * Advanced interface
    , connect
    , Hakase(..)
      -- * Re-exports
    , module Hakase.Common
    ) where

import Control.Applicative ((<|>))
import Control.Exception (throw)
import Control.Monad.Catch (MonadMask)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (evalStateT, get, put)
import Data.Attoparsec.Combinator (endOfInput)
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text.IO as Text
import Data.Traversable (for)
import Network.Simple.TCP (HostName, ServiceName)
import qualified Network.Simple.TCP as Network
import Prelude hiding (init)
import System.IO.Error (eofErrorType, mkIOError)
import qualified System.IO.Streams as Streams
import qualified System.IO.Streams.Attoparsec as Streams

import Hakase.Common


hakase
    :: (MonadIO m, MonadMask m)
    => (Text -> Int -> (Move, s))
        -- ^ Given the opponent's name and number of rounds, compute the first move
    -> (Move -> s -> (Move, s))
        -- ^ Given the opponent's last move, compute the next move
    -> Text
        -- ^ Client name
    -> HostName
        -- ^ Server host name
    -> ServiceName
        -- ^ Server port
    -> m ()
hakase init next =
    hakaseM
        (\opponent numMoves -> return $ init opponent numMoves)
        (\lastMove s -> return $ next lastMove s)


hakaseM
    :: (MonadIO m, MonadMask m)
    => (Text -> Int -> m (Move, s))
        -- ^ Given the opponent's name and number of rounds, compute the first move
    -> (Move -> s -> m (Move, s))
        -- ^ Given the opponent's last move, compute the next move
    -> Text
        -- ^ Client name
    -> HostName
        -- ^ Server host name
    -> ServiceName
        -- ^ Server port
    -> m ()
hakaseM init next name host port = connect host port $ \h -> do
    (opponent, numMoves) <- liftIO $ do
        -- Perform the handshake
        send h $ Hello name protocolVersion
        Welcome server <- recv h
        Text.putStrLn $ "connected to server " <> server
        -- Wait for a challenger
        Start opponent numMoves <- liftIO $ recv h
        Text.putStrLn $ "matched with opponent " <> opponent <> ", "
            <> textShow numMoves <> " rounds"
        return (opponent, numMoves)
    let loop = for [1 .. numMoves] $ \_ -> do
            -- Compute the next move
            m <- get
            (nextMove, !s') <- case m of
                Nothing -> lift $ init opponent (fromIntegral numMoves)
                Just (lastMove, s) -> lift $ next lastMove s
            -- Send our move to the server, and receive the opponent's in
            -- response
            Move oppMove <- liftIO $ do
                send h $ Move nextMove
                recv h
            -- Store the updated state
            put $ Just (oppMove, s')
            -- Determine the winner of this round
            let result = winner nextMove oppMove
            liftIO . Text.putStrLn $ textShow nextMove <> " × "
                <> textShow oppMove <> "  →  " <> showResult result
            return result
    results <- evalStateT loop Nothing
    liftIO . Text.putStrLn $
        textShow (length $ filter (== GT) results) <> " wins, "
        <> textShow (length $ filter (== LT) results) <> " losses, "
        <> textShow (length $ filter (== EQ) results) <> " draws"
  where
    showResult r = case r of
        LT -> "LOSE"
        EQ -> "DRAW"
        GT -> "WIN"


-- | Represents a connection to the Hakase server.
data Hakase = Hakase
    { recv :: IO Command
        -- ^ Wait for a message from the server.
        --
        -- Throws an exception if the underlying socket has been closed.
    , send :: Command -> IO ()
        -- ^ Send a message to the server.
    }


-- | Connect to a Hakase server.
--
-- This is a low-level function; as such, users must perform handshaking and
-- maintain protocol invariants themselves.
connect
    :: (MonadIO m, MonadMask m)
    => HostName -> ServiceName
    -> (Hakase -> m r) -> m r
connect host port k = Network.connect host port $ \(sock, _) -> do
    (is, os) <- liftIO $ Streams.socketToStreams sock
    is' <- liftIO $ Streams.parserToInputStream parseCommand' is
    k Hakase
        { recv = Streams.read is' >>= maybe (throw eofError) return
        , send = \c -> Streams.write (Just $ renderCommand c) os
        }
  where
    parseCommand' = Nothing <$ endOfInput <|> Just <$> parseCommand
    eofError = mkIOError eofErrorType "end of stream" Nothing Nothing