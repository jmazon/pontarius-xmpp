-- | XEP 0077: In-Band Registration
-- http://xmpp.org/extensions/xep-0077.html

{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Xmpp.Xep.InbandRegistration where

import           Control.Applicative((<$>))
import           Control.Arrow(left)
import           Control.Exception
import           Control.Monad.Except
import           Control.Monad.State

import           Data.Either (partitionEithers)
import qualified Data.Text as Text
import           Data.XML.Pickle
import qualified Data.XML.Types as XML

import           Network.Xmpp.Internal
import           Network.Xmpp.Xep.ServiceDiscovery


-- In-Band Registration name space
ibrns :: Text.Text
ibrns = "jabber:iq:register"

ibrName x = (XML.Name x (Just ibrns) Nothing)

data IbrError = IbrNotSupported
              | IbrNoStream
              | IbrIQError IQError
              | IbrTimeout

                deriving (Show)

data Query = Query { instructions :: Maybe Text.Text
                   , registered   :: Bool
                   , remove       :: Bool
                   , fields       ::[(Field, Maybe Text.Text)]
                   } deriving Show

emptyQuery = Query Nothing False False []

query :: IQRequestType -> Query -> Stream -> IO (Either IbrError Query)
query queryType x con = do
    answer <- pushIQ "ibr" Nothing queryType Nothing (pickleElem xpQuery x) con
    case answer of
        Right IQResult{iqResultPayload = Just b} ->
            case unpickleElem xpQuery b of
                Right query -> return $ Right query
                Left e -> throw . StreamXMLError $
                            "RequestField: unpickle failed, got "
                            ++ Text.unpack (ppUnpickleError e)
                            ++ " saw " ++ ppElement b
        Right _ -> return $ Right emptyQuery -- TODO: That doesn't seem right
        Left e -> return . Left $ IbrIQError e

query' :: IQRequestType -> Query -> Session -> IO (Either IbrError Query)
query' queryType x con = do
    answer <- sendIQ' Nothing queryType Nothing (pickleElem xpQuery x) con
    case answer of
        IQResponseResult IQResult{iqResultPayload = Just b} ->
            case unpickleElem xpQuery b of
                Right query -> return $ Right query
                Left e -> throw . StreamXMLError $
                            "RequestField: unpickle failed, got "
                            ++ Text.unpack (ppUnpickleError e)
                            ++ " saw " ++ ppElement b
        IQResponseResult _ -> return $ Right emptyQuery -- TODO: That doesn't
                                                        -- seem right
        IQResponseError e -> return . Left $ IbrIQError e
        IQResponseTimeout -> return . Left $ IbrTimeout


data RegisterError = IbrError IbrError
                   | MissingFields   [Field]
                   | AlreadyRegistered
                     deriving (Show)

mapError f = mapErrorT (liftM $ left f)

-- | Retrieve the necessary fields and fill them in to register an account with
-- the server.
registerWith :: [(Field, Text.Text)]
             -> Stream
             -> IO  (Either RegisterError Query)
registerWith givenFields con = runExceptT $ do
    fs <- mapError IbrError . ExceptT $ requestFields con
    when (registered fs) . throwError $ AlreadyRegistered
    let res = flip map (fields fs) $ \(field,_) ->
            case lookup field givenFields of
                Just entry -> Right (field, Just entry)
                Nothing -> Left field
    fields <- case partitionEithers res of
        ([],fs) -> return fs
        (fs,_) -> throwError $ MissingFields fs
    result <- mapError IbrError . ExceptT $ query Set (emptyQuery {fields}) con
    return result



createAccountWith host hostname port fields = runExceptT $ do
      con' <- liftIO $ connectTcp host port hostname
      con <- case con' of
          Left e -> throwError $ IbrError IbrNoConnection
          Right r -> return r
      lift $ startTLS exampleParams con
      ExceptT $ registerWith fields con

deleteAccount host hostname port username password = do
    con <- simpleConnect host port hostname username password Nothing
    unregister' con
--    endsession con

-- | Terminate your account on the server. You have to be logged in for this to
-- work. You connection will most likely be terminated after unregistering.
unregister :: Stream -> IO (Either IbrError Query)
unregister = query Set $ emptyQuery {remove = True}

unregister' :: Session -> IO (Either IbrError Query)
unregister' = query' Set $ emptyQuery {remove = True}

requestFields con = runExceptT $ do
    qr <- ExceptT $ query Get emptyQuery con
    return $ qr

xpQuery :: PU [XML.Node] Query
xpQuery = xpWrap
            (\(is, r, u, fs) -> Query is r u fs)
            (\(Query is r u fs) -> (is, r, u, fs)) $
            xpElemNodes (ibrName "query") $
              xp4Tuple
                 (xpOption $
                    xpElemNodes (ibrName "instructions") (xpContent $ xpText))
                 (xpElemExists (ibrName "registered"))
                 (xpElemExists (ibrName "remove"))
                 (xpAllByNamespace ibrns  ( xpWrap
                                              (\(name,_,c) -> (name, c))
                                              (\(name,c) -> (name,(),c)) $
                         xpElemByNamespace ibrns xpPrim xpUnit
                           (xpOption $ xpContent xpText)
                        ))

data Field = Username
           | Nick
           | Password
           | Name
           | First
           | Last
           | Email
           | Address
           | City
           | State
           | Zip
           | Phone
           | Url
           | Date
           | Misc
           | Text
           | Key
           | OtherField Text.Text
             deriving Eq

instance Show Field where
    show  Username       = "username"
    show  Nick           = "nick"
    show  Password       = "password"
    show  Name           = "name"
    show  First          = "first"
    show  Last           = "last"
    show  Email          = "email"
    show  Address        = "address"
    show  City           = "city"
    show  State          = "state"
    show  Zip            = "zip"
    show  Phone          = "phone"
    show  Url            = "url"
    show  Date           = "date"
    show  Misc           = "misc"
    show  Text           = "text"
    show  Key            = "key"
    show  (OtherField x) = Text.unpack x

instance Read Field where
    readsPrec _ "username" = [(Username     , "")]
    readsPrec _ "nick"     = [(Nick         , "")]
    readsPrec _ "password" = [(Password     , "")]
    readsPrec _ "name"     = [(Name         , "")]
    readsPrec _ "first"    = [(First        , "")]
    readsPrec _ "last"     = [(Last         , "")]
    readsPrec _ "email"    = [(Email        , "")]
    readsPrec _ "address"  = [(Address      , "")]
    readsPrec _ "city"     = [(City         , "")]
    readsPrec _ "state"    = [(State        , "")]
    readsPrec _ "zip"      = [(Zip          , "")]
    readsPrec _ "phone"    = [(Phone        , "")]
    readsPrec _ "url"      = [(Url          , "")]
    readsPrec _ "date"     = [(Date         , "")]
    readsPrec _ "misc"     = [(Misc         , "")]
    readsPrec _ "text"     = [(Text         , "")]
    readsPrec _ "key"      = [(Key          , "")]
    readsPrec _ x          = [(OtherField $ Text.pack x , "")]



-- Registered
-- Instructions

ppElement :: Element -> String
ppElement = Text.unpack . Text.decodeUtf8 . renderElement
