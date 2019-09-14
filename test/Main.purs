module Test.Main where

import Prelude

import Control.Monad.Error.Class (throwError)
import Data.Either (isLeft)
import Data.UUID (genUUID, toString)
import Data.Unfoldable (replicateA)
import Effect (Effect)
import Effect.Aff (attempt)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import MySQL.Connection (defaultConnectionInfo, execute, query)
import MySQL.Pool (Pool, closePool, createPool, defaultPoolInfo, withPool)
import MySQL.QueryValue (toQueryValue)
import MySQL.Transaction (withTransaction)
import Test.Unit (suite, test)
import Test.Unit.Assert as Assert
import Test.Unit.Main (runTest)

type User =
  { id :: String
  , name :: String
  }

main :: Effect Unit
main = runTest do
  test "Queries" do
    pool <- liftEffect createPool'

    flip withPool pool \conn -> do
      userId <- liftEffect $ genUUID <#> toString
      let userName = "dummy_name_" <> userId
      execute
        "INSERT INTO users (id, name) VALUES (?, ?)"
        [ toQueryValue userId, toQueryValue userName ]
        conn
      users <- query
        "SELECT * FROM users WHERE id = ?"
        [ toQueryValue userId ]
        conn
      Assert.equal
        [ { id: userId, name: userName } ]
        users

    liftEffect $ closePool pool

  suite "Transaction" do
    test "Commit" do
      pool <- liftEffect createPool'

      flip withPool pool \conn -> do
        xs <- liftEffect $ replicateA 2
          $ genUUID <#> toString <#> \id -> { id, name: "dummy_name_" <> id }
        flip withTransaction conn $ execute
          "INSERT INTO users (id, name) VALUES ?"
          [ toQueryValue $ (xs <#> \x -> [ x.id, x.name ]) ]
        users <- query
          "SELECT * FROM users WHERE id IN (?) ORDER BY FIELD(id, ?)"
          [ toQueryValue $ xs <#> _.id, toQueryValue $ xs <#> _.id ]
          conn
        Assert.equal xs users

      liftEffect $ closePool pool

    test "Rollback" do
      pool <- liftEffect createPool'

      flip withPool pool \conn -> do
        (xs :: Array User) <- liftEffect $ replicateA 2
          $ genUUID <#> toString <#> \id -> { id, name: "dummy_name_" <> id }
        result <- attempt $ flip withTransaction conn \conn' -> do
          execute
            "INSERT INTO users (id, name) VALUES ?"
            [ toQueryValue $ (xs <#> \x -> [ x.id, x.name ]) ]
            conn'
          throwError $ error "Rollback Test"
        Assert.assert "Error was ignored" $ isLeft result
        users <- query
          "SELECT * FROM users WHERE id IN (?) ORDER BY FIELD(id, ?)"
          [ toQueryValue $ xs <#> _.id, toQueryValue $ xs <#> _.id ]
          conn
        Assert.equal ([] :: Array User) users

      liftEffect $ closePool pool

createPool' :: Effect Pool
createPool' = createPool connInfo defaultPoolInfo
  where
    connInfo = defaultConnectionInfo
      { host = "127.0.0.1"
      , database = "purescript_mysql"
      }
