{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forever)
import Data.Monoid ((<>))
import Network.Simple.TCP
import Options.Applicative

import Hakase.Server


main :: IO ()
main = do
    (hp, port) <- execParser opts
    hakaseServer $ \k ->
        listen hp port $ \(lsock, laddr) -> do
            putStrLn $ "starting server on " ++ show laddr
            forever $ acceptFork lsock $ \(sock, addr) -> do
                putStrLn $ "client connected: " ++ show addr
                k =<< clientFromSocket sock
  where
    opts = info (helper <*> args)
        ( fullDesc
        <> progDesc "Run a server that speaks the Hakase Rock-Paper-Scissors protocol"
        <> header "hakase-server - a server that speaks the Hakase Rock-Paper-Scissors protocol" )

    args = (,)
        <$> argument auto
            ( metavar "HOST"
            <> value "localhost"
            <> help "Host name to bind to" )
        <*> strArgument
            ( metavar "PORT"
            <> value "6266"
            <> help "Port to bind to" )