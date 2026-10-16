{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Genesis (prepare) where

import qualified Cardano.Api as Api
import qualified Cardano.Api.Experimental.Certificate as Certificate
import qualified Cardano.Ledger.BaseTypes as Ledger
import Cardano.Ledger.Binary (natVersion)
import qualified Cardano.Ledger.Shelley.Core as Core
import qualified Cardano.Ledger.Shelley.Genesis as Shelley

import Data.Aeson (ToJSON, Value (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LBS
import Data.Function ((&))
import qualified Data.ListMap as ListMap
import Data.Ratio ((%))
import qualified Data.Text.IO as Text
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Lens.Micro ((.~))
import System.FilePath ((</>))

-- Generate one private stake pool, one funded payment address and independent
-- owners for the token child and ADA sibling. The caller
-- supplies a fresh, private directory and runs this executable from the root
-- checkout, so the templates come from the declared node submodule.
prepare :: FilePath -> IO ()
prepare directory = do
    payment <- Api.generateSigningKey Api.AsPaymentKey
    tokenOwner <- Api.generateSigningKey Api.AsPaymentKey
    siblingOwner <- Api.generateSigningKey Api.AsPaymentKey
    stake <- Api.generateSigningKey Api.AsStakeKey
    pool <- Api.generateSigningKey Api.AsStakePoolKey
    kes <- Api.generateSigningKey Api.AsKesKey
    vrf <- Api.generateSigningKey Api.AsVrfKey
    now <- getCurrentTime
    let startSeconds = ceiling (utcTimeToPOSIXSeconds (addUTCTime 5 now)) :: Integer
        startTime = posixSecondsToUTCTime (fromInteger startSeconds)
        network = Api.Testnet (Api.NetworkMagic 42)
        poolKey = Api.getVerificationKey pool
        poolHash@(Api.StakePoolKeyHash ledgerPoolHash) = Api.verificationKeyHash poolKey
        stakeHash@(Api.StakeKeyHash ledgerStakeHash) = Api.verificationKeyHash (Api.getVerificationKey stake)
        stakeCredential = Api.StakeCredentialByKey stakeHash
        ownerAddress signingKey =
            Api.makeShelleyAddress
                network
                (Api.PaymentCredentialByKey (Api.verificationKeyHash (Api.getVerificationKey signingKey)))
                (Api.StakeAddressByValue stakeCredential)
        address = ownerAddress payment
        tokenOwnerAddress = ownerAddress tokenOwner
        siblingOwnerAddress = ownerAddress siblingOwner
        poolParameters =
            Certificate.toShelleyPoolParams $
                Certificate.StakePoolParameters
                    { Certificate.stakePoolId = poolHash
                    , Certificate.stakePoolVRF = Api.verificationKeyHash (Api.getVerificationKey vrf)
                    , Certificate.stakePoolBlsKey = Nothing
                    , Certificate.stakePoolCost = 0
                    , Certificate.stakePoolMargin = 15 % 1000
                    , Certificate.stakePoolRewardAccount = Api.makeStakeAddress network stakeCredential
                    , Certificate.stakePoolPledge = 0
                    , Certificate.stakePoolOwners = [stakeHash]
                    , Certificate.stakePoolRelays = []
                    , Certificate.stakePoolMetadata = Nothing
                    }
        shelley =
            Api.shelleyGenesisDefaults
                { Api.sgSystemStart = startTime
                , Api.sgNetworkMagic = 42
                , Api.sgSecurityParam = Ledger.knownNonZeroBounded @5
                , Api.sgActiveSlotsCoeff = Api.unsafeBoundedRational (1 % 10)
                , Api.sgEpochLength = Ledger.EpochSize 500
                , Api.sgSlotLength = 0.1
                , Api.sgSlotsPerKESPeriod = 129600
                , Api.sgMaxKESEvolutions = 60
                , Api.sgUpdateQuorum = 1
                , Api.sgMaxLovelaceSupply = 1000000000000
                , Api.sgProtocolParams =
                    Api.sgProtocolParams Api.shelleyGenesisDefaults
                        & Core.ppProtocolVersionL .~ Ledger.ProtVer (natVersion @12) 0
                , Api.sgInitialFunds =
                    ListMap.fromList
                        [(Api.toShelleyAddr (Api.shelleyAddressInEra Api.ShelleyBasedEraShelley address), 900000000000)]
                , Api.sgStaking =
                    Shelley.ShelleyGenesisStaking
                        { Shelley.sgsPools = ListMap.fromList [(ledgerPoolHash, poolParameters)]
                        , Shelley.sgsStake = ListMap.fromList [(ledgerStakeHash, ledgerPoolHash)]
                        }
                , Api.sgExtraConfig = Ledger.SNothing
                }
    either (fail . show) pure (Shelley.validateGenesis shelley)
    (certificate, _) <-
        either (fail . show) pure $
            Certificate.issueOperationalCertificate
                (Api.getVerificationKey kes)
                (Left (Api.AnyStakePoolNormalSigningKey pool))
                (Certificate.KESPeriod 0)
                (Certificate.OperationalCertificateIssueCounter 0 poolKey)
    writeEnvelope "payment.skey" payment
    writeEnvelope "token-owner.skey" tokenOwner
    writeEnvelope "sibling-owner.skey" siblingOwner
    writeEnvelope "stake.skey" stake
    writeEnvelope "pool.skey" pool
    writeEnvelope "node.kes.skey" kes
    writeEnvelope "node.vrf.skey" vrf
    writeEnvelope "node.opcert" certificate
    Text.writeFile (directory </> "address.txt") (Api.serialiseAddress address <> "\n")
    Text.writeFile (directory </> "token-owner-address.txt") (Api.serialiseAddress tokenOwnerAddress <> "\n")
    Text.writeFile (directory </> "sibling-owner-address.txt") (Api.serialiseAddress siblingOwnerAddress <> "\n")
    writeJSON directory "shelley-genesis.json" shelley
    writeJSON directory "alonzo-genesis.json" Api.alonzoGenesisDefaults
    writeJSON directory "conway-genesis.json" Api.conwayGenesisDefaults
    writeJSON directory "dijkstra-genesis.json" Api.dijkstraGenesisDefaults

    -- Cardano mode requires a Byron genesis even when it transitions through
    -- Byron at epoch zero. It has no funds or producers; Shelley injects both.
    byronParameters <- readTemplate "testnet-template-byron.json"
    writeJSON directory "byron-genesis.json" $
        object
            [ "bootStakeholders" .= object []
            , "heavyDelegation" .= object []
            , "startTime" .= startSeconds
            , "nonAvvmBalances" .= object []
            , "blockVersionData" .= byronParameters
            , "protocolConsts" .= object ["k" .= (5 :: Int), "protocolMagic" .= (42 :: Int)]
            , "avvmDistr" .= object []
            ]
    template <- readTemplate "testnet-template-config.json"
    config <- case template of
        Object fields ->
            pure . Object $
                KeyMap.union
                    ( KeyMap.fromList
                        [ ("ExperimentalHardForksEnabled", Bool True)
                        , ("ExperimentalProtocolsEnabled", Bool True)
                        , ("TestShelleyHardForkAtEpoch", Number 0)
                        , ("TestAllegraHardForkAtEpoch", Number 0)
                        , ("TestMaryHardForkAtEpoch", Number 0)
                        , ("TestAlonzoHardForkAtEpoch", Number 0)
                        , ("TestBabbageHardForkAtEpoch", Number 0)
                        , ("TestConwayHardForkAtEpoch", Number 0)
                        , ("TestDijkstraHardForkAtEpoch", Number 1)
                        , ("LastKnownBlockVersion-Major", Number 10)
                        , ("LastKnownBlockVersion-Minor", Number 0)
                        , ("ConsensusMode", String "PraosMode")
                        , ("LedgerDB", object ["Backend" .= String "V2InMemory"])
                        , ("LeiosDbConfig", object ["Backend" .= String "InMemory"])
                        ,
                            ( "TraceOptions"
                            , object
                                [ ""
                                    .= object
                                        [ "backends" .= [String "Stdout HumanFormatColoured"]
                                        , "detail" .= String "DNormal"
                                        , "severity" .= String "Info"
                                        ]
                                ]
                            )
                        ]
                    )
                    fields
        _ -> fail "Node configuration template must be a JSON object"
    writeJSON directory "config.json" config
    writeJSON directory "topology.json" $
        object
            [ "localRoots" .= ([] :: [Value])
            , "publicRoots" .= ([] :: [Value])
            , "useLedgerAfterSlot" .= (-1 :: Int)
            , "bootstrapPeers" .= Null
            ]
  where
    writeEnvelope :: (Api.HasTextEnvelope a) => FilePath -> a -> IO ()
    writeEnvelope name value =
        Api.writeFileTextEnvelopeWithOwnerPermissions (Api.File (directory </> name)) Nothing value
            >>= either (fail . show) pure

readTemplate :: FilePath -> IO Value
readTemplate name =
    Aeson.eitherDecodeFileStrict' ("cardano-node/configuration/cardano" </> name)
        >>= either fail pure

writeJSON :: (ToJSON a) => FilePath -> FilePath -> a -> IO ()
writeJSON directory name value = LBS.writeFile (directory </> name) (Aeson.encode value <> "\n")
