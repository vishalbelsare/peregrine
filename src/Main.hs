{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Protocol.Tmx.TAQ as TAQ
import Protocol
import Protocol.Backend.C.Base as C

import           Language.C.Quote.C
import qualified Language.C.Syntax as C
import qualified Language.C.Utils as C
import           Language.C.Smart ((+=))
import           Language.C.Utils (C, CompUnit, depends, include, noloc)
import           Language.C.Utils (topDecl, require)
import           Language.C.Utils (char, bool, ushort, uint, ulong)

import Data.List (intercalate, sort)
import Data.Maybe (listToMaybe)
import Data.Char (isSpace)

import Text.PrettyPrint.Mainland (putDocLn, ppr, pretty, prettyPragma, Pretty(..))
import Text.InterpolatedString.Perl6 (q, qc)

import Data.Text as T (unpack)

import Utils

import Development.Shake
import Development.Shake.FilePath

import System.IO.Unsafe (unsafePerformIO)

taqCSpec :: C.Specification TAQ
taqCSpec = C.Specification
  { _mkTy       = mkTy
  , _readMember = readMember
  , _handleMsg  = handleMsgGroupBy
  , _initMsg    = initMsgGroupBy
  , _cleanupMsg = cleanupMsgGroupBy
  }

-- shamelessly taken from neat-interpolation
dedent :: String -> String
dedent s = case minimumIndent s of
  Just len -> unlines $ map (drop len) $ lines s
  Nothing  -> s
  where
    minimumIndent = listToMaybe . sort . map (length . takeWhile (==' '))
      . filter (not . null . dropWhile isSpace) . lines

noop :: C.Stm
noop = [cstm|/*no-op*/(void)0;|]

initMsgGroupBy :: Message TAQ -> C C.Stm
initMsgGroupBy msg = pure noop

handleMsgGroupBy = handleMsgGroupBy__ (+=) (getField id "Symbol" taq "trade")

handleMsgGroupBy__ :: (C.Exp -> C.Exp -> C.Stm) -> Field TAQ -> Message TAQ -> C C.Stm
handleMsgGroupBy__ mkStmt field msg = case _msgName msg of
  "trade" -> do
    symbol <- C.simplety <$> mkTy field
    let price = uint
    cppmap <- cpp_unordered_map symbol price
    topDecl [cdecl|$ty:cppmap groupby;|]
    return $ mkStmt [cexp|groupby[msg.trade.symbol]|] [cexp|msg.trade.price|]
  _ -> pure noop

trace :: Show a => a -> a
trace a = unsafePerformIO $ print a >> return a

showc :: Pretty c => c -> String
showc = pretty 0 . ppr

cleanupMsgGroupBy :: Message TAQ -> C C.Stm
cleanupMsgGroupBy msg = case _msgName msg of
  "trade" -> pure [cstm|
    for ($ty:auto it = groupby.begin(); it != groupby.end(); ++it) {
      printf("%.8s %d\n", &it->first, it->second);
    }|]
  _ -> pure noop
  where
    auto = [cty|typename $id:("auto")|]

handleMsgGzip :: Message TAQ -> C C.Stm
handleMsgGzip msg = do
  struct <- require $ genStruct mkTy msg
  return [cstm|write($id:(fdName msg).writefd,
          &msg.$id:(C.getId struct),
          sizeof(struct $id:(C.getId struct)));|]
  where
    cnm = rawIden . cname . _msgName

cpp_string :: C C.Type
cpp_string = do
  include "string"
  return [cty|typename $id:("std::string")|]

cpp_unordered_map :: C.Type -> C.Type -> C C.Type
cpp_unordered_map k v = do
  include "unordered_map"
  return [cty|typename $id:ty|]
  where
    ty :: String = [qc|std::unordered_map<{showc k}, {showc v}>|]
    -- sk           = tostr k
    -- sv           = tostr v

assert :: Bool -> a -> a
assert pred a = if pred then a else (error "Assertion failed")

symbol :: C C.Type
symbol = do
  hash <- depends [cedecl|$esc:esc|]
  depends [cty|struct symbol { $ty:ulong symbol; }|]
  return [cty|typename $id:("struct symbol")|]
  where
    esc = dedent [q|
      namespace std {
        template <> struct hash<struct symbol> {
          uint64_t operator()(const struct symbol& k) const {
            return hash<uint64_t>()(k.symbol);
          }
        };
        template <> struct equal_to<struct symbol> {
          bool operator() (const struct symbol& x, const struct symbol& y)
            const
          {
            return equal_to<uint64_t>()(x.symbol, y.symbol);
          }
        };
      }
    |]

mkTy :: Field TAQ -> C C.GType
mkTy f@(Field _ len _ ty _) = do
  symbol__ <- require symbol
  let ret
        | ty==Numeric    && len==9 = C.SimpleTy uint
        | ty==Numeric    && len==7 = C.SimpleTy uint
        | ty==Numeric    && len==3 = C.SimpleTy ushort
        | ty==Numeric              = error $ "Unknown integer len for " ++ show f
        | ty==Alphabetic && len==1 = C.SimpleTy char
        | ty==Alphabetic           = C.SimpleTy symbol__
        | ty==Boolean              = assert (len==1) $ C.SimpleTy bool
        | ty==Date                 = C.SimpleTy uint -- assert?
        | ty==Time                 = C.SimpleTy uint -- assert?
        | otherwise                = error "Unknown case."
  return ret

readMember ofst f@(Field _ len nm ty _) = case ty of

  Numeric    -> runIntegral
  Alphabetic -> return $ if len == 1
                  then [cstm|dst->$id:cnm = *$buf;|]
                  else [cstm|memcpy(&dst->$id:cnm, $buf, $len);|]
  Boolean    -> return [cstm|dst->$id:cnm = (*$buf == '1');|]
  Date       -> runIntegral
  Time       -> runIntegral
  where
    buf = [cexp|buf + $ofst|]
    runIntegral = do
      dep <- cReadIntegral =<< (C.simplety <$> mkTy f)
      return [cstm|dst->$id:cnm = $id:(C.getId dep) ($buf, $len); |]

    cnm     = rawIden (cname nm)

cReadIntegral ty = do
  mapM include ["cstdint", "cassert", "cctype"]
  depends impl
  where
    funName :: String = [qc|parse_{pretty 0 $ ppr ty}|]
    impl = [cfun|
      $ty:ty $id:(funName) (char const *buf, $ty:uint len) {
        $ty:ty ret = 0;
        while (len--) {
          assert(isdigit(*buf));
          ret = ret * 10 + (*buf - '0');
          ++buf;
        }
        return ret;
      }
    |]

printFmt :: C.Exp -> Message TAQ -> (String, [C.Exp])
printFmt root msg = let
  (fmts, ids) = unzip $ fmt <$> _fields msg
  in (intercalate ", " fmts, mconcat ids)
  where
    fmt (Field _ len nm ty _)
      | ty==Numeric     = ([qc|{nm}: %d|], [exp nm])
      | ty==Alphabetic  = ([qc|{nm}: %.{len}s|], [[cexp|&$(exp nm)|]])
      | ty==Boolean     = ([qc|{nm}: %d|], [exp nm])
      | ty==Date        = ([qc|{nm}: %d|], [exp nm])
      | ty==Time        = ([qc|{nm}: %d|], [exp nm])
    exp nm = [cexp|$root.$id:(rawIden $ cname nm)|]

fdName :: Message a -> String
fdName msg = rawIden $ cname $ _msgName msg

initMsgGzip :: Message a -> C C.Stm
initMsgGzip msg = do
  str <- require cpp_string
  mapM include
    ["cstdio", "cstdlib", "unistd.h", "sys/types.h", "sys/wait.h", "fcntl.h"]
  depends [cty|struct spawn { int writefd; int pid; }|]
  topDecl [cdecl|struct spawn $id:(fdName msg);|]
  depends [cfun|struct spawn spawn_child(char const *filename, char const *progname, char const *argv0) {
    int fds[2];
    int ret;
    if ((ret = pipe(fds)) < 0) {
      perror("pipe");
      exit(ret);
    }
    int readfd  = fds[0];
    int writefd = fds[1];

    int cpid = fork();
    if (cpid < 0) {
      perror("fork");
      exit(1);
    }
    /* parent */
    if (cpid) {
      close(readfd);
      struct spawn ret;
      ret.writefd = writefd;
      ret.pid     = cpid;
      return ret;
    } else {
      close(writefd);
      /* stdin from pipe */
      if ((ret = dup2(readfd, STDIN_FILENO)) < 0) {
        perror("dup2");
        exit(ret);
      }
      int outfd = open(filename, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
      if (outfd < 0) {
        perror("open output");
        exit(outfd);
      }
      /* pipe to file */
      if ((ret = dup2(outfd, STDOUT_FILENO)) < 0) {
        perror("dup2");
        exit(ret);
      }
      if ((ret = execlp(progname, argv0, 0)) < 0) {
        perror("execlp");
        exit(ret);
      }
    }
  }|]
  str <- require cpp_string
  let mkStr = [cexp|$id:("std::string")|]
  return [cstm|{
    $ty:str filename = $mkStr("out/")
        + $mkStr(argv[1]) + $mkStr($(outputName :: String));
    $id:(fdName msg) =
      spawn_child(filename.c_str(), $codecStr, $(codecStr ++ auxName));
    }|]
  where
    outputName = [qc|.{fdName msg}.{suffix}|]
    auxName    = [qc| ({fdName msg})|]
    suffix     = "gz"
    codecStr   = "gzip"

cleanupMsgGzip :: Message a -> C C.Stm
cleanupMsgGzip msg = do
  initMsgGzip msg -- pull dependencies
  return [cstm|{close  ($id:(fdName msg).writefd);
              /* don't wait for them or else strange hang occurs.
               * without waiting, there is a small race condition between
               * when the parent finishes and when the gzip children finish.
               * fprintf(stderr, "Waiting %d\n", $id:(fdName msg).pid);
               * waitpid($id:(fdName msg).pid, NULL, 0); */
                ;}|]

main = do

  shakeArgs shakeOptions $ do

    compile "bin" (cmain taqCSpec taq)

    let exe = "bin/a.out"

    "data/*.lz4" %> \out -> do
      let src = "/mnt/efs/ftp/tmxdatalinx.com" </> (takeFileName out) -<.> "gz"
      need [src]
      command [Shell] [qc|gzip -d < {src} | lz4 -9 > {out}|] []

    let date = "20150826"
    phony "Run a.out" $ do
      let dataFile = [qc|data/{date}TradesAndQuotesDaily.lz4|]
      need [dataFile, exe]
      command_ [Shell] [qc|lz4 -d < {dataFile} | {exe} {date} |] []

    want ["Run a.out"]

