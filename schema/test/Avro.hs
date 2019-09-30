{-# language OverloadedStrings, TypeApplications,
             NamedFieldPuns #-}
module Main where

import Data.Avro
import qualified Data.ByteString.Lazy as BS
import System.Environment

import Mu.Schema ()
import Mu.Schema.Adapter.Avro ()
import Mu.Schema.Examples

exampleAddress :: Address
exampleAddress = Address "1111BB" "Spain"

examplePerson1, examplePerson2 :: Person
examplePerson1 = Person "Haskellio" "Gómez" (Just 30) (Just Male) exampleAddress
examplePerson2 = Person "Cuarenta" "Siete" Nothing Nothing exampleAddress

main :: IO ()
main = do -- Obtain the filenames
          [genFile, conFile] <- getArgs
          -- Read the file produced by Python
          putStrLn "haskell/consume"
          cbs <- BS.readFile conFile
          let [people] = decodeContainer @Person cbs
          print people
          -- Encode a couple of values
          putStrLn "haskell/generate"
          print [examplePerson1, examplePerson2]
          gbs <- encodeContainer [[examplePerson1, examplePerson2]]
          BS.writeFile genFile gbs