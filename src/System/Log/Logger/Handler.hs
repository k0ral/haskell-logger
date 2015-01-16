{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  System.Log.Logger.Handler
-- Copyright   :  (C) 2015 Flowbox
-- License     :  Apache-2.0
-- Maintainer  :  Wojciech Daniło <wojciech.danilo@gmail.com>
-- Stability   :  stable
-- Portability :  portable
-----------------------------------------------------------------------------

module System.Log.Logger.Handler where

import           Data.Monoid
import           Control.Applicative
import           System.Log.Data               (MonadRecord(appendRecord), LogBuilder, LookupDataSet, Msg, Lvl)
import           System.Log.Filter             (Filter, runFilter)
import           Control.Lens                  hiding (children)
import           System.Log.Log                (Log, MonadLogger(appendLog), LogFormat, LogFormat)
import           Control.Monad.Trans           (lift)
import           Control.Monad.State           (StateT, runStateT)
import qualified Control.Monad.State           as State
import           Control.Monad.IO.Class        (MonadIO, liftIO)
import           System.Log.Format             (Formatter, runFormatter, defaultFormatter)
import           Text.PrettyPrint.ANSI.Leijen  (Doc, putDoc)
import Control.Monad.Trans (MonadTrans)


----------------------------------------------------------------------
-- MonadLoggerHandler
----------------------------------------------------------------------

class MonadLoggerHandler n m | m -> n where
    addHandler :: Handler n (LogFormat m) -> m ()

    default addHandler :: (Monad m, MonadTrans t) => Handler n (LogFormat m) -> t m ()
    addHandler = lift . addHandler

----------------------------------------------------------------------
-- Handler
----------------------------------------------------------------------

-- !!! dorobic formattery i filtracje do handlerow!

data Handler m l = Handler { _name      :: String
                           , _action    :: Doc -> Log l -> m ()
                           , _children  :: [Handler m l]
                           , _formatter :: Maybe (Formatter l)
                           , _filters   :: [Filter l]
                           }
makeLenses ''Handler

type Handler' m = Handler m (LogFormat m)

instance Show (Handler m l) where
    show (Handler n _ _ _ _) = "Handler " <> n

mkHandler :: String -> (Doc -> Log l -> m ()) -> Maybe (Formatter l) -> Handler m l
mkHandler name f fmt = Handler name f [] fmt []
addChildHandler h ph = ph & children %~ (h:)

addFilter :: Filter l -> Handler m l -> Handler m l
addFilter f = filters %~ (f:)

setFormatter :: Formatter l -> Handler m l -> Handler m l
setFormatter f = formatter .~ (Just f)

-- === Handlers ===

topHandler fmt = mkHandler "TopHandler" (\_ _ -> return ()) Nothing
               & formatter .~ (Just fmt)

printHandler = mkHandler "PrintHandler" handle where
    handle defDoc l = liftIO $ putDoc defDoc *> putStrLn ""

----------------------------------------------------------------------
-- HandlerLogger
----------------------------------------------------------------------

newtype HandlerLogger m a = HandlerLogger { fromHandlerLogger :: StateT (Handler' (HandlerLogger m)) m a } deriving (Monad, MonadIO, Applicative, Functor)

type instance LogFormat (HandlerLogger m) = LogFormat m

instance MonadTrans HandlerLogger where
    lift = HandlerLogger . lift

runHandlerLoggerT :: (Functor m, Monad m) => Formatter (LogFormat m) -> HandlerLogger m b -> m b
runHandlerLoggerT fmt = fmap fst . flip runStateT (topHandler fmt) . fromHandlerLogger


runHandler :: (Applicative m, Monad m) => Doc -> Log (LogFormat m) -> Handler' m -> m ()
runHandler defDoc l h = act <* mapM (runHandler doc l) (h^.children) where
    flt = runFilters h l
    fmt = h^.formatter
    act = if flt then (h^.action) doc l
                 else return ()
    doc = case fmt of
        Nothing -> defDoc
        Just f  -> runFormatter f l
    runFilters h l = foldr (&&) True $ fmap (\f -> runFilter f l) (h^.filters)


getTopHandler = HandlerLogger State.get
putTopHandler = HandlerLogger . State.put

-- === Instances ===

instance (MonadLogger m, Functor m, l~LogFormat m, LookupDataSet Msg l, LookupDataSet Lvl l)
      => MonadLogger (HandlerLogger m) where
    appendLog l =  (runHandler defDoc l =<< getTopHandler) 
                *> lift (appendLog l)
        where defDoc = runFormatter defaultFormatter l

instance (Monad m, Functor m) => MonadLoggerHandler (HandlerLogger m) (HandlerLogger m) where
    addHandler h = do
        topH <- getTopHandler
        putTopHandler $ addChildHandler h topH

instance (Functor m, MonadLogger m, l~LogFormat m, LogBuilder d (HandlerLogger m), LookupDataSet Msg l, LookupDataSet Lvl l) 
      => MonadRecord d (HandlerLogger m)