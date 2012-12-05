{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Xmpp.Concurrent.Monad where

import           Network.Xmpp.Types

import           Control.Applicative((<$>))
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TVar (TVar, readTVar, writeTVar)
import qualified Control.Exception.Lifted as Ex
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.State.Strict

import           Data.IORef
import qualified Data.Map as Map
import           Data.Text(Text)

import           Network.Xmpp.Concurrent.Types
import           Network.Xmpp.Connection




-- TODO: Wait for presence error?

-- | Run an XmppConMonad action in isolation. Reader and writer workers will be
-- temporarily stopped and resumed with the new session details once the action
-- returns. The action will run in the calling thread. Any uncaught exceptions
-- will be interpreted as connection failure.
withConnection :: XmppConMonad a -> Session -> IO (Either StreamError a)
withConnection a session =  do
    wait <- newEmptyTMVarIO
    Ex.mask_ $ do
        -- Suspends the reader until the lock (wait) is released (set to `()').
        throwTo (readerThread session) $ Interrupt wait
        -- We acquire the write and stateRef locks, to make sure that this is
        -- the only thread that can write to the stream and to perform a
        -- withConnection calculation. Afterwards, we release the lock and
        -- fetches an updated state.
        s <- Ex.catch
            (atomically $ do
                 _ <- takeTMVar  (writeRef session)
                 s <- takeTMVar (conStateRef session)
                 putTMVar wait ()
                 return s
            )
            -- If we catch an exception, we have failed to take the MVars above.
            (\e -> atomically (putTMVar wait ()) >>
                 Ex.throwIO (e :: Ex.SomeException)
            )
        -- Run the XmppMonad action, save the (possibly updated) states, release
        -- the locks, and return the result.
        Ex.catches
            (do
                 (res, s') <- runStateT a s
                 atomically $ do
                     putTMVar (writeRef session) (cSend . sCon $ s')
                     putTMVar (conStateRef session) s'
                     return $ Right res
            )
            -- We treat all Exceptions as fatal. If we catch a StreamError, we
            -- return it. Otherwise, we throw an exception.
            [ Ex.Handler $ \e -> return $ Left (e :: StreamError)
            , Ex.Handler $ \e -> runStateT xmppKillConnection s
                  >> Ex.throwIO (e :: Ex.SomeException)
            ]

-- | Executes a function to update the event handlers.
modifyHandlers :: (EventHandlers -> EventHandlers) -> Session -> IO ()
modifyHandlers f session = atomically $ modifyTVar (eventHandlers session) f
  where
    -- Borrowing modifyTVar from
    -- http://hackage.haskell.org/packages/archive/stm/2.4/doc/html/src/Control-Concurrent-STM-TVar.html
    -- as it's not available in GHC 7.0.
    modifyTVar :: TVar a -> (a -> a) -> STM ()
    modifyTVar var f = do
      x <- readTVar var
      writeTVar var (f x)

-- | Sets the handler to be executed when the server connection is closed.
setConnectionClosedHandler :: (StreamError -> Session -> IO ()) -> Session -> IO ()
setConnectionClosedHandler eh session = do
    modifyHandlers (\s -> s{connectionClosedHandler =
                                 \e -> eh e session}) session

-- | Run an event handler.
runHandler :: (EventHandlers -> IO a) -> Session -> IO a
runHandler h session = h =<< atomically (readTVar $ eventHandlers session)


-- | End the current Xmpp session.
endSession :: Session -> IO ()
endSession session =  do -- TODO: This has to be idempotent (is it?)
    void $ withConnection xmppKillConnection session
    stopThreads session

-- | Close the connection to the server. Closes the stream (by enforcing a
-- write lock and sending a </stream:stream> element), waits (blocks) for three
-- seconds, and then closes the connection.
closeConnection :: Session -> IO ()
closeConnection session = Ex.mask_ $ do
    send <- atomically $ takeTMVar (writeRef session)
    cc <- cClose . sCon <$> ( atomically $ readTMVar (conStateRef session))
    send "</stream:stream>"
    void . forkIO $ do
      threadDelay 3000000
      -- When we close the connection, we close the handle that was used in the
      -- sCloseConnection above. So even if a new connection has been
      -- established at this point, it will not be affected by this action.
      (Ex.try cc) :: IO (Either Ex.SomeException ())
      return ()
    atomically $ putTMVar (writeRef session) (\_ -> return False)
