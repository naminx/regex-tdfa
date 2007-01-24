{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
-- | This is a version of ReadRegex that allows NUL characters.
-- Lazy/Possessive/Backrefs are not recognized.  Anchors ^ and $ are
-- now recognized (they used to be errors).
module Text.Regex.TDFA.ReadRegex (PatternIndex,parseRegex,decodePatternSet,legalCharacterClasses) where

{- By Chris Kuklewicz, 2006. BSD License, see the LICENSE file. -}

import Text.Regex.TDFA.Pattern
import Text.ParserCombinators.Parsec((<|>), (<?>),
  unexpected, try, runParser, many, getState, setState, GenParser, ParseError,
  sepBy1, option, notFollowedBy, many1, lookAhead, eof, between,
  string, noneOf, digit, char, anyChar)
import Control.Monad(liftM, when, guard)
import qualified Data.Set as Set(fromList, toList, insert,empty)

-- | BracketElement is internal only
data BracketElement = BEChar Char | BEChars String | BEColl String | BEEquiv String | BEClass String

parseRegex :: String -> Either ParseError (Pattern,(PatternIndex,Int))
parseRegex x = runParser (do pat <- p_regex
                             eof
                             subs <- getState
                             return (pat,subs)) (0,0) x x

p_regex :: GenParser Char (PatternIndex,Int) Pattern
p_regex = liftM POr $ sepBy1 p_branch (char '|')

-- man re_format helps alot, it says one-or-more pieces so this is
-- many1 not many.  Use "()" to indicate an empty piece.
p_branch = liftM PConcat $ many1 p_piece

p_piece = (p_anchor <|> p_atom) >>= p_post_atom -- correct specification

p_atom =  p_group <|> p_bracket <|> p_char <?> "an atom"

group_index = do
  (gi,ci) <- getState
  let index = succ gi
  setState (index,ci)
  return index

p_group = lookAhead (char '(') >> do
  index <- group_index
  liftM (PGroup index) $ between (char '(') (char ')') p_regex

-- p_post_atom takes the previous atom as a parameter
p_post_atom atom = (char '?' >> return (PQuest atom))
               <|> (char '+' >> return (PPlus atom))
               <|> (char '*' >> return (PStar True atom))
               <|> p_bound atom 
               <|> return atom

p_bound atom = try $ between (char '{') (char '}') (p_bound_spec atom)

p_bound_spec atom = do lowS <- many1 digit
                       let lowI = read lowS
                       highMI <- option (Just lowI) $ try $ do 
                                   char ','
                                   highS <- many digit
                                   if null highS then return Nothing -- no upper bound
                                     else do let highI = read highS
                                             guard (lowI <= highI)
                                             return (Just (read highS))
                       return (PBound lowI highMI atom)

-- An anchor cannot be modified by a repetition specifier
p_anchor = (char '^' >> liftM PCarat char_index)
       <|> (char '$' >> liftM PDollar char_index)
       <|> try (do string "()" 
                   index <- group_index
                   return $ PGroup index PEmpty) 
       <?> "empty () or anchor ^ or $"

char_index = do (gi,ci) <- getState
                let ci' = succ ci
                setState (gi,ci')
                return (newDoPa ci')

p_char = p_dot <|> p_left_brace <|> p_escaped <|> p_other_char where
  p_dot = char '.' >> char_index >>= return . PDot
  p_left_brace = try $ (char '{' >> notFollowedBy digit >> char_index >>= return . (`PChar` '{'))
  p_escaped = char '\\' >> anyChar >>= \c -> char_index >>= return . (`PEscape` c)
  p_other_char = noneOf specials >>= \c -> char_index >>= return . (`PChar` c) 
  specials  = "^.[$()|*+?{\\"

-- parse [bar] and [^bar] sets of characters
p_bracket = (char '[') >> ( (char '^' >> p_set True) <|> (p_set False) )

-- p_set does not support [.ch.] or [=y=] or [:foo:]
-- p_set :: Bool -> GenParser Char st Pattern
p_set invert = do initial <- (option "" ((char ']' >> return "]") <|> (char '-' >> return "-")))
                  values <- many1 p_set_elem
                  char ']'
                  ci <- char_index
                  let chars = maybe'set $ initial
                                          ++ [c | BEChar c <- values ]
                                          ++ concat [s | BEChars s <- values ]
                      colls = maybe'set [PatternSetCollatingElement coll | BEColl coll <- values ]
                      equivs = maybe'set [PatternSetEquivalenceClass equiv | BEEquiv equiv <- values]
                      class's = maybe'set [PatternSetCharacterClass a'class | BEClass a'class <- values]
                      maybe'set x = if null x then Nothing else Just (Set.fromList x)
                      sets = PatternSet chars class's colls equivs
                  sets `seq` return $ if invert then PAnyNot ci sets else PAny ci sets

-- From here down the code is the parser and functions for pattern [ ] set things

p_set_elem = p_set_elem_class <|> p_set_elem_equiv <|> p_set_elem_coll
         <|> p_set_elem_range <|> p_set_elem_char <?> "Failed to parse bracketed string"

p_set_elem_class = liftM BEClass $
  try (between (string "[:") (string ":]") (many1 $ noneOf ":]"))

p_set_elem_equiv = liftM BEEquiv $
  try (between (string "[=") (string "=]") (many1 $ noneOf "=]"))

p_set_elem_coll =  liftM BEColl $
  try (between (string "[.") (string ".]") (many1 $ noneOf ".]"))

p_set_elem_range = try $ do 
  start <- noneOf "]-"
  char '-'
  end <- noneOf "]"
  return (BEChars [start..end])

p_set_elem_char = do 
  c <- noneOf "]"
  when (c == '-') $ do
    atEnd <- (lookAhead (char ']') >> return True) <|> (return False)
    when (not atEnd) (unexpected "A dash is in the wrong place in a bracket")
  return (BEChar c)

-- | decodePatternSet cannot handle collating element and treats
-- equivalence classes as just their definition and nothing more.
decodePatternSet (PatternSet msc mscc _ msec) =
  let baseMSC = maybe Set.empty id msc
      withMSCC = foldl (flip Set.insert) baseMSC  (maybe [] (concatMap decodeCharacterClass . Set.toList) mscc)
      withMSEC = foldl (flip Set.insert) withMSCC (maybe [] (concatMap unSEC . Set.toList) msec)
  in withMSEC

legalCharacterClasses = ["alnum","digit","punct","alpha","graph"
  ,"space","blank","lower","upper","cntrl","print","xdigit","word"]

decodeCharacterClass (PatternSetCharacterClass s) =
  case s of
    "alnum" -> ['0'..'9']++['a'..'z']++['A'..'Z']
    "digit" -> ['0'..'9']
    "punct" -> ['\33'..'\47']++['\58'..'\64']++['\91'..'\95']++"\96"++['\123'..'\126']
    "alpha" -> ['a'..'z']++['A'..'Z']
    "graph" -> ['\41'..'\126']
    "space" -> "\t\n\v\f\r "
    "blank" -> "\t "
    "lower" -> ['a'..'z']
    "upper" -> ['A'..'Z']
    "cntrl" -> ['\0'..'\31']++"\127" -- with NUL
    "print" -> ['\32'..'\126']
    "xdigit" -> ['0'..'9']++['a'..'f']++['A'..'F']
    "word" -> ['0'..'9']++['a'..'z']++['A'..'Z']++"_"
    _ -> []

