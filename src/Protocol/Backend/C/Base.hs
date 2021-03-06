{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
module Protocol.Backend.C.Base where

import           Language.C.Utils as C

import           Protocol

import           Development.Shake

import           Text.PrettyPrint.Mainland (putDocLn, pretty, prettyPragma)
import           Text.PrettyPrint.Mainland.Class (Pretty(..))
import           Text.InterpolatedString.Perl6
import           Data.String.Interpolate.IsString

import           Data.Bits
import           Data.List (intercalate)

import           Utils
import           Data.Monoid

import           Control.Monad
import           Control.Arrow
import           Control.Lens

import           System.IO.Unsafe (unsafePerformIO)
import           System.IO
import           System.Process.Typed
import           System.Exit (ExitCode(..))
import           Control.Exception

data Specification a = Specification
  { _proto      :: Proto a
  , _mkTy       :: Field a -> C Type
  , _readMember :: Field a -> C.Exp -> C.Exp -> C Code
  }

data CField = CField { _cty :: C Type, _readField :: Exp -> Exp -> C Code }

cproto :: Specification a -> Proto CField
cproto spec@(Specification proto _ _) = proto
  { _outgoingMessages = cmessage spec <$> _outgoingMessages proto
  , _incomingMessages = cmessage spec <$> _incomingMessages proto
  }

cmessage :: Specification a -> Message a -> Message CField
cmessage spec msg = msg & fields %~ fmap (cfield spec)

cfield :: Specification a -> Field a -> Field CField
cfield spec f = f & atype .~ (CField (mkTy f) (readMember f))
  where
    mkTy       = _mkTy spec
    readMember = _readMember spec

-- Overlapping since CField has no Eq instance
instance {-# OVERLAPPING #-} Eq (Field CField) where
  -- == ignoring the CField parameter
  a == b = (() <$ a) == (() <$ b)
 
-- Overlapping since CField has no Ord instance
instance {-# OVERLAPPING #-} Ord (Field CField) where
  -- compare ignoring the CField parameter
  a `compare` b = (() <$ a) `compare` (() <$ b)
 
deriving instance {-# OVERLAPPING #-} Eq (Message CField)
deriving instance {-# OVERLAPPING #-} Ord (Message CField)
deriving instance {-# OVERLAPPING #-} Eq (Proto CField)
deriving instance {-# OVERLAPPING #-} Ord (Proto CField)
 
data MsgHandler = MsgHandler
  { _handleMsg  :: Message CField -> C Code
  , _initMsg    :: Message CField -> C Code
  , _cleanupMsg :: Message CField -> C Code
  }

-- non-overlapping monoid instance for (a -> m b)
mempty_ :: (Applicative t, Monoid m) => (a -> t m)
mempty_ _ = pure mempty
mappend_ :: (Applicative t, Monoid m) => (a -> t m) -> (a -> t m) -> (a -> t m)
mappend_ f g = \a -> (<>) <$> f a <*> g a

instance Monoid MsgHandler where
  mempty = MsgHandler empty empty empty
    where empty = const (return mempty)
  mappend (MsgHandler h1 i1 c1) (MsgHandler h2 i2 c2) = MsgHandler h3 i3 c3
    where
      h3 = h1 `mappend_` h2
      i3 = i1 `mappend_` i2
      c3 = c1 `mappend_` c2

cstruct :: Identifier -> [(Type, Identifier)] -> C C.Type
cstruct name members = do
  cty [i|struct ${name} {
    ${body}
  }|]
  return [i|struct ${name}|]
  where
    body = concatMap (\(ty, id) -> [i|${ty} ${id};|]) members

cnm :: String -> Identifier
cnm = Identifier . rawIden . cname

genStruct :: Message CField -> C C.Type
genStruct msg = do
  decls <- runDecls
  cstruct (cnm $ _msgName msg) decls
  where
    runDecls = forM (_fields msg) $ \f -> do
      ty <- _cty (_atype f)
      return (ty, cnm (_name f))

readStruct :: Message CField -> C Identifier
readStruct msg = do
  include "cstring"
  genStruct msg
  require impl
  return funName
  where
    impl = do
      pureStms <- mkStms
      cfun [i|
        void ${funName} (struct ${structName} *dst, char const *buf) {
          ${concat pureStms}
        }
      |]
    funName :: Identifier = [qc|read_{structName}|]
    structName        = cnm $ _msgName msg
    ofsts             = scanl (+) 0 (_len <$> _fields msg)
    read ofst field   = (_readField (_atype field))
      [i|dst->${cnm (_name field)}|]
      [i|buf + ${ofst}|]
    mkStms            = zipWithM read ofsts (_fields msg)
 
mainLoop :: Specification a -> MsgHandler -> C Identifier
mainLoop spec handler@(MsgHandler {..}) = do
  let proto = cproto spec
  include "stdio.h"

  structs :: [Code] <- forM (_outgoingMessages proto) $ \msg -> do
    struct <- genStruct msg
    return [i|struct ${cnm $ _msgName msg} ${cnm $ _msgName msg}|]

  cases :: [Code] <- forM (_outgoingMessages proto) $ \msg -> do
    readMsg   <- readStruct msg
    struct    <- genStruct msg
    handleMsg <- _handleMsg msg
    let prefix = Exp [i|msg.${cnm $ _msgName msg}|]
 
    return [i|case ${_tag msg} : {
 
      if (fread(buf, 1, ${bodyLen proto msg}, stdin) == 0) {
        return -1;
      }
      /* parse struct */
      ${readMsg} (&msg.${cnm $ _msgName msg}, buf);
 
      ${handleMsg}
 
      break;
 
    }|]

  include "cassert"
  let
    readHeader = if _pktHdrLen proto > 0
      then [i|
        if (fread(buf, 1, ${_pktHdrLen proto}, stdin) == 0) {
          return -1;
        }|]
      else []
    funName = "handle"

  cfun [i|
    int ${funName}(char *buf) {
      union {
        ${intercalate "\n" $ (++";") `map` structs}
      } msg;
      (void)0;/* Read the packet header if any */
      ${readHeader}
      (void)0;/* Read the packet type */
      if (fread(buf, 1, 1, stdin) == 0) {
        return -1;
      }
      switch (*buf) {
        ${intercalate "\n" cases}
        default: {
          assert(false);
          return -1;
        }
      }
      return 1;
    }
  |]
  return (Identifier funName)
 
cmain :: Specification a -> MsgHandler -> C C.Func
cmain spec handler@(MsgHandler {..}) = do
  include "cstdio"
  loopStep     <- mainLoop spec handler
  initMsgs     <- _initMsg `mapM` _outgoingMessages proto
  cleanupMsgs  <- _cleanupMsg `mapM` _outgoingMessages proto
 
  cfun [i|int main(int argc, char **argv) {
    ${concat initMsgs}
    char buf[${bufLen}];
    int ret = 0;
    int pkts = 0;
 
    while(ret >= 0) {
      ret = ${loopStep}(buf);
      ++pkts;
    }
 
    fprintf(stderr, "Cleaning up.\\n");
    ${concat cleanupMsgs}
    fprintf(stderr, "%d packets\\n", pkts);
 
  }|]
  where
    proto      = cproto spec
    bufLen     = maximum $ foreach (_outgoingMessages proto) $
      rotateL (1::Int) . (+1) . logBase2 . bodyLen proto
 
    logBase2 x = finiteBitSize x - 1 - countLeadingZeros x

codeGen :: Bool -> C a -> String
codeGen dbg code = clang_format . s 80 . ppr $ mkCompUnit code
  where
    s = if dbg
      then prettyPragma
      else pretty

clang_format :: String -> String
clang_format cpp = unsafePerformIO $ do
  out <- readProcessStdout_ extern_clang_format
  return $ decodeUtf8String out
  where
    extern_clang_format = proc "clang-format"
      [ [i|-assume-filename=cpp|]
      , filter (/='\n') $ trim $ dedent [i|
            -style=
            { BasedOnStyle: Google
            , BreakBeforeBraces: Linux
            , NamespaceIndentation: All
            }
          |]
      ]
      & setStdin (byteStringInput (encodeUtf8String cpp))

type Debug = Bool

data CCompiler = GCC | Clang

compile :: CompileOptions -> FilePath -> C a -> IO ()
compile (CompileOptions dbg optLevel compiler oname) buildDir code = do
  timer "codegen" $ writeFile src (codeGen False code)
  hPutStrLn stderr $ "## " ++ cmd
  timer "compile" $ runProcess_ (shell cmd)
  where
    cmd = [qc|{cc} -std=c++11 -march=native -O{optLevel} {dbgFlag} -o {out} {src}|]
    cc  = compilerCmd compiler
    src :: String = [qc|{buildDir}/{oname}.cpp|]
    out :: String = [qc|{buildDir}/{oname}|]
    dbgFlag = if dbg then "-g" else ""

compilerCmd :: CCompiler -> String
compilerCmd compiler = case compiler of
  GCC   -> "g++"
  Clang -> "clang++"

data CompileOptions = CompileOptions
  { debug    :: Debug
  , optLevel :: Int
  , compiler :: CCompiler
  , filename :: FilePath
  }
 
compileShake :: CompileOptions -> FilePath -> C a -> Rules ()
compileShake (CompileOptions dbg optLevel compiler oname) buildDir code = do
 
  let
    src = [qc|{buildDir}/{oname}.cpp|]
    out = [qc|{buildDir}/{oname}|]
    cc  = compilerCmd compiler
 
  src %> \out -> do
    alwaysRerun
    writeFileChanged out $ codeGen dbg code
 
  out %> \out -> do
 
    need [src]
 
    let dbgFlag = switch "-g" "" dbg
    command_ [Cwd buildDir, Shell] -- Compile
      [qc|{cc} -std=c++11 -march=native -O{optLevel} {dbgFlag} -o {oname} {oname}.cpp|] []
 
    command_ [Cwd buildDir, Shell] -- Grab the demangled assembly
      [qc|objdump -Cd {oname} > {oname}.s|] []
 
