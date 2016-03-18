{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
module Protocol.Backend.C.Base where

import qualified Language.C.Syntax as C
import           Language.C.Quote.C

import           Language.C.Utils as C

import           Protocol

import           Development.Shake

import           Text.PrettyPrint.Mainland (putDocLn, ppr, pretty, prettyPragma)
import           Text.InterpolatedString.Perl6 (qc)

import           Data.Bits

import           Utils
import           Data.Monoid

import           Control.Monad

data Specification a = Specification
  { _mkTy       :: Field a -> C C.GType
  , _readMember :: Int -> Field a -> C C.Stm
  }

data MsgHandler a = MsgHandler
  { _handleMsg  :: Message a -> C [C.Stm]
  , _initMsg    :: Message a -> C [C.Stm]
  , _cleanupMsg :: Message a -> C [C.Stm]
  }

-- non-overlapping monoid instance for (a -> m b)
mempty_ :: (Applicative t, Monoid m) => (a -> t m)
mempty_ _ = pure mempty
mappend_ :: (Applicative t, Monoid m) => (a -> t m) -> (a -> t m) -> (a -> t m)
mappend_ f g = \a -> (<>) <$> f a <*> g a

instance Monoid (MsgHandler a) where
  mempty = MsgHandler empty empty empty
    where empty = const (return mempty)
  mappend (MsgHandler h1 i1 c1) (MsgHandler h2 i2 c2) = MsgHandler h3 i3 c3
    where
      h3 = h1 `mappend_` h2
      i3 = i1 `mappend_` i2
      c3 = c1 `mappend_` c2

cstruct :: String -> [C.FieldGroup] -> C C.Type
cstruct name membs = do
  depends [cty|struct $id:name {
    $sdecls:membs
  }|]
  return [cty|typename $id:("struct "++name)|]

genStruct :: Specification a -> Message a -> C C.Type
genStruct spec msg = do
  decls <- runDecls
  cstruct (_msgName msg) decls
  where
    runDecls = mapM declare (_fields msg)
    declare f@(Field _ len nm ty _) = mkCsdecl (rawIden $ cname nm) <$> mkTy f
    mkTy = _mkTy spec

mkCsdecl :: String -> C.GType -> C.FieldGroup                                   
mkCsdecl nm (C.SimpleTy ty)   = [csdecl|$ty:ty $id:nm;|]
mkCsdecl nm (C.ArrayTy ty sz) = [csdecl|$ty:ty $id:nm[$sz]; |]
 
readStruct :: Specification a -> Message a -> C C.Func
readStruct spec@(Specification {..}) msg = do
  include "cstring"
  require (genStruct spec msg)
  require impl
  where
    impl = do
      pureStms <- stms
      depends [cfun|
        void $id:(funName) (struct $id:(structName) *dst, char const *buf) {
          $stms:pureStms
        }
      |]
    funName :: String = [qc|read_{_msgName msg}|]
    structName        = _msgName msg
    ofsts             = scanl (+) 0 (_len <$> _fields msg)
    stms              = zipWithM _readMember ofsts (_fields msg)
 
mainLoop :: Specification a -> MsgHandler a -> Proto a -> C C.Func
mainLoop spec@(Specification {..}) handler@(MsgHandler {..}) proto = do
  include "stdio.h"
  cases <- forM (_outgoingMessages proto) $ \msg -> do
    readMsg   <- readStruct spec msg
    struct    <- require $ genStruct spec msg
    handleMsg <- _handleMsg msg
    let prefix = [cexp|msg.$id:(_msgName msg)|]
 
    return [cstm|case $exp:(_tag msg) : {
 
      if (fread(buf, 1, $(bodyLen proto msg), stdin) == 0) {
        return -1;
      }
      /* parse struct */
      $id:(getId readMsg) (&msg.$id:(_msgName msg), buf);
 
      $stms:(handleMsg)
 
      break;
 
    }|]
  structs <- forM (_outgoingMessages proto) $ \msg -> do
    struct <- require $ genStruct spec msg
    return [csdecl|struct $id:(_msgName msg) $id:(_msgName msg);|]
 
  depends [cfun|
    int handle(char *buf) {
      union {
        $sdecls:structs
      } msg;
      if (fread(buf, 1, 1, stdin) == 0) {
        return -1;
      }
      switch (*buf) {
        $stms:cases
        default: {
          assert("Failed to read tag.");
          return -1;
        }
      }
      return 1;
    }
  |]
 
cmain :: Specification a -> MsgHandler a -> Proto a -> C C.Func
cmain spec@(Specification {..}) handler@(MsgHandler {..}) proto = do
  include "cstdio"
  loopStep     <- mainLoop spec handler proto
  initMsgs     <- _initMsg `mapM` _outgoingMessages proto
  cleanupMsgs  <- _cleanupMsg `mapM` _outgoingMessages proto
 
  depends [cfun|int main(int argc, char **argv) {
    $stms:(concat initMsgs)
    char buf[$bufLen];
    int ret = 0;
    int pkts = 0;
 
    while(ret >= 0) {
      ret = $id:(getId loopStep) (buf);
      ++pkts;
      if (pkts % 1000000 == 0) {
        fprintf(stderr, "Checkpoint! %d\n", pkts);
      }
    }
 
    fprintf(stderr, "Cleaning up.\n");
    $stms:(concat cleanupMsgs)
    fprintf(stderr, "%d packets\n", pkts);
 
  }|]
  where
    bufLen     = maximum $ foreach (_outgoingMessages proto) $
      rotateL (1::Int) . (+1) . logBase2 . bodyLen proto
 
    logBase2 x = finiteBitSize x - 1 - countLeadingZeros x

compile :: Bool -> C a -> String
compile dbg code = s 80 $ ppr $ mkCompUnit code
  where
    s = switch prettyPragma pretty dbg
 
compileShake :: Bool -> String -> C a -> Rules ()
compileShake dbg buildDir code = do
 
  let src = [qc|{buildDir}/main.cpp|]
  let out = [qc|{buildDir}/a.out|]
 
  src %> \out -> do
    alwaysRerun
    writeFileChanged out $ compile dbg code
 
  out %> \out -> do
 
    need [src]
 
    let dbgFlag = switch "-g" "" dbg
    command_ [Cwd buildDir, Shell] -- Compile
      [qc|g++ -std=c++11 -march=native -O2 {dbgFlag} main.cpp|] []
 
    command_ [Cwd buildDir, Shell] -- Grab the demangled assembly
      [qc|objdump -Cd a.out > main.s|] []
 

