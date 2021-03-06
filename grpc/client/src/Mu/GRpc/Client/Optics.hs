{-# language AllowAmbiguousTypes    #-}
{-# language DataKinds              #-}
{-# language FlexibleInstances      #-}
{-# language FunctionalDependencies #-}
{-# language GADTs                  #-}
{-# language RankNTypes             #-}
{-# language ScopedTypeVariables    #-}
{-# language TypeApplications       #-}
{-# language TypeFamilies           #-}
{-# language TypeOperators          #-}
{-# language UndecidableInstances   #-}
{-|
Description : Client for gRPC services using optics and labels

For further information over initialization of the connection,
consult the <http://hackage.haskell.org/package/http2-client-grpc http2-client-grpc docs>.
-}
module Mu.GRpc.Client.Optics (
  -- * Initialization of the gRPC client
  GRpcConnection
, initGRpc
, initGRpcZipkin
, GRpcMessageProtocol(..)
, msgProtoBuf
, msgAvro
, G.GrpcClientConfig
, G.grpcClientConfigSimple
  -- * Request arguments and responses
, CompressMode
, GRpcReply(..)
  -- * Re-exported for convenience
, module Optics.Core
, module Mu.Schema.Optics
) where

import           Control.Monad.IO.Class
import qualified Data.ByteString.Char8       as BS
import           Data.Conduit
import           Data.Proxy
import           Data.Text                   as T
import           GHC.TypeLits
import           Monitor.Tracing
import           Network.GRPC.Client         (CompressMode)
import qualified Network.GRPC.Client.Helpers as G
import           Network.HTTP2.Client        (ClientError)
import           Optics.Core

import           Mu.GRpc.Bridge
import           Mu.GRpc.Client.Internal
import           Mu.Rpc
import           Mu.Schema
import           Mu.Schema.Optics

-- | Represents a connection to the service @s@.
newtype GRpcConnection (s :: Package') (p :: GRpcMessageProtocol)
  = GRpcConnection { gcClient  :: G.GrpcClient }

-- | Initializes a connection to a gRPC server.
--   Usually the service you are connecting to is
--   inferred from the usage later on.
--   However, it can also be made explicit by using
--
--   > initGRpc config msgProtoBuf @Service
--
initGRpc :: MonadIO m
         => G.GrpcClientConfig  -- ^ gRPC configuration
         -> Proxy p
         -> forall s. m (Either ClientError (GRpcConnection s p))
initGRpc config _ = do
  setup <- setupGrpcClient' config
  pure $ case setup of
    Left e  -> Left e
    Right c -> Right $ GRpcConnection c

-- | Initializes a connection to a gRPC server,
--   creating a new span for distributed tracing.
--   Usually the service you are connecting to is
--   inferred from the usage later on.
--   However, it can also be made explicit by using
--
--   > initGRpcZipkin config msgProtoBuf "person" @Service
--
initGRpcZipkin :: (MonadIO m, MonadTrace m)
               => G.GrpcClientConfig  -- ^ gRPC configuration
               -> Proxy p
               -> T.Text
               -> forall s. m (Either ClientError (GRpcConnection s p))
initGRpcZipkin config _ spanName = do
  setup <- setupGrpcClientZipkin config spanName
  pure $ case setup of
    Left e  -> Left e
    Right c -> Right $ GRpcConnection c

instance forall (pkg :: Package') (pkgName :: Symbol)
                (service :: Service') (serviceName :: Symbol)
                (methods :: [Method'])
                (p :: GRpcMessageProtocol) (m :: Symbol) t.
         ( pkg ~ 'Package ('Just pkgName) '[service]
         , service ~ 'Service serviceName methods
         , SearchMethodOptic p methods m t
         , KnownName serviceName
         , KnownName pkgName
         , KnownName m
         , MkRPC p )
         => LabelOptic m A_Getter
                       (GRpcConnection pkg p)
                       (GRpcConnection pkg p)
                       t t where
  labelOptic = to (searchMethodOptic @p (Proxy @methods) (Proxy @m) rpc . gcClient)
    where pkgName = BS.pack (nameVal (Proxy @pkgName))
          svrName = BS.pack (nameVal (Proxy @serviceName))
          metName = BS.pack (nameVal (Proxy @m))
          rpc = mkRPC (Proxy @p) pkgName svrName metName

class SearchMethodOptic (p :: GRpcMessageProtocol) (methods :: [Method']) (m :: Symbol) t
      | p methods m -> t where
  searchMethodOptic :: Proxy methods -> Proxy m -> RPCTy p -> G.GrpcClient -> t

{- Not possible due to functional dependency
instance TypeError ('Text "could not find method " ':<>: ShowType m)
         => SearchMethodOptic '[] m t where
-}
instance {-# OVERLAPS #-} MethodOptic p ('Method name ins outs) t
         => SearchMethodOptic p ('Method name ins outs ': rest) name t where
  searchMethodOptic _ _ rpc = methodOptic @p rpc (Proxy @('Method name ins outs))
instance {-# OVERLAPPABLE #-} SearchMethodOptic p rest name t
         => SearchMethodOptic p ('Method other ins outs ': rest) name t where
  searchMethodOptic _ = searchMethodOptic @p (Proxy @rest)

class GRpcMethodCall p method t
      => MethodOptic (p :: GRpcMessageProtocol) (method :: Method') t
      | p method -> t where
  methodOptic :: RPCTy p -> Proxy method -> G.GrpcClient -> t
  methodOptic = gRpcMethodCall @p

-- No arguments
instance forall (name :: Symbol) t p.
         ( GRpcMethodCall p ('Method name '[ ] 'RetNothing) t
         , t ~ IO (GRpcReply ()) )
         => MethodOptic p ('Method name '[ ] 'RetNothing) t
instance forall (name :: Symbol) (sch :: Schema Symbol Symbol) (r :: Symbol) t p.
         ( GRpcMethodCall p ('Method name '[ ] ('RetSingle ('SchemaRef sch r))) t
         , t ~ IO (GRpcReply (Term sch (sch :/: r))) )
         => MethodOptic p ('Method name '[ ] ('RetSingle ('SchemaRef sch r))) t
instance forall (name :: Symbol) (sch :: Schema Symbol Symbol) (r :: Symbol) t p.
         ( GRpcMethodCall p ('Method name '[ ] ('RetStream ('SchemaRef sch r))) t
         , t ~ IO (ConduitT () (GRpcReply (Term sch (sch :/: r))) IO ()) )
         => MethodOptic p ('Method name '[ ] ('RetStream ('SchemaRef sch r))) t
-- Simple arguments
instance forall (name :: Symbol) (sch :: Schema Symbol Symbol) (v :: Symbol) aname t p.
         ( GRpcMethodCall p ('Method name '[ 'ArgSingle aname ('SchemaRef sch v) ] 'RetNothing) t
         , t ~ (Term sch (sch :/: v) -> IO (GRpcReply ())) )
         => MethodOptic p ('Method name '[ 'ArgSingle aname ('SchemaRef sch v) ] 'RetNothing) t
instance forall (name :: Symbol) (sch :: Schema Symbol Symbol) (v :: Symbol) (r :: Symbol) aname t p.
         ( GRpcMethodCall p ('Method name '[ 'ArgSingle aname ('SchemaRef sch v) ] ('RetSingle ('SchemaRef sch r))) t
         , t ~ (Term sch (sch :/: v)
               -> IO (GRpcReply (Term sch (sch :/: r))) ) )
         => MethodOptic p ('Method name '[ 'ArgSingle aname ('SchemaRef sch v)  ] ('RetSingle ('SchemaRef sch r))) t
instance forall (name :: Symbol) (sch :: Schema Symbol Symbol) (v :: Symbol) (r :: Symbol) aname t p.
         ( GRpcMethodCall p ('Method name '[ 'ArgSingle aname ('SchemaRef sch v)  ] ('RetStream ('SchemaRef sch r))) t
         , t ~ (Term sch (sch :/: v)
                ->  IO (ConduitT () (GRpcReply (Term sch (sch :/: r))) IO ()) ) )
         => MethodOptic p ('Method name '[ 'ArgSingle aname ('SchemaRef sch v)  ] ('RetStream ('SchemaRef sch r))) t
-- Stream arguments
instance forall (name :: Symbol) (sch :: Schema Symbol Symbol) (v :: Symbol) (r :: Symbol) aname t p.
         ( GRpcMethodCall p ('Method name '[ 'ArgStream aname ('SchemaRef sch v) ] ('RetSingle ('SchemaRef sch r))) t
         , t ~ (CompressMode
                -> IO (ConduitT (Term sch (sch :/: v))
                                Void IO
                                (GRpcReply (Term sch (sch :/: r))))) )
         => MethodOptic p ('Method name '[ 'ArgStream aname ('SchemaRef sch v)  ] ('RetSingle ('SchemaRef sch r))) t
instance forall (name :: Symbol) (sch :: Schema Symbol Symbol) (v :: Symbol) (r :: Symbol) aname t p.
         ( GRpcMethodCall p ('Method name '[ 'ArgStream aname ('SchemaRef sch v)  ] ('RetStream ('SchemaRef sch r))) t
         , t ~ (CompressMode
               -> IO (ConduitT (Term sch (sch :/: v))
                               (GRpcReply (Term sch (sch :/: r))) IO ())) )
         => MethodOptic p ('Method name '[ 'ArgStream aname ('SchemaRef sch v)  ] ('RetStream ('SchemaRef sch r))) t
