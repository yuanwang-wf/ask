module ChkRaw where

import Data.List
import qualified Data.Map as M

import Thin
import Bwd
import LexAsk
import RawAsk
import Tm

data Setup = Setup
  { introRules :: [Rule]
  , weirdRules :: [Rule]
  , fixities   :: FixityTable
  } deriving Show

byRules :: Setup -> [Rule]
byRules s = introRules s ++ weirdRules s

mySetup :: Setup
mySetup = Setup
  { introRules = myIntroRules
  , weirdRules = myWeirdRules
  , fixities   = myFixities
  }

myFixities :: FixityTable
myFixities = M.fromList
  [ ("&", (7, RAsso))
  , ("|", (6, RAsso))
  , ("->", (1, RAsso))
  ]

data Rule =
  (Pat, Pat) :<=
  [ Tm
  ]
  deriving Show

myIntroRules :: [Rule]
myIntroRules =
  [ (PC "&" [PM "a" mempty, PM "b" mempty], PC "AndI" []) :<=
    [ TC "prove" [TM "a" []]
    , TC "prove" [TM "b" []]
    ]
  , (PC "|" [PM "a" mempty, PM "b" mempty], PC "OrIL" []) :<=
    [ TC "prove" [TM "a" []]
    ]
  , (PC "|" [PM "a" mempty, PM "b" mempty], PC "OrIR" []) :<=
    [ TC "prove" [TM "b" []]
    ]
  , (PC "->" [PM "a" mempty, PM "b" mempty], PC "ImpI" []) :<=
    [ TC "given" [TM "a" [], TC "prove" [TM "b" []]]
    ]
  , (PC "True" [], PC "True" []) :<= []
  ]

myWeirdRules :: [Rule]
myWeirdRules =
  [ (PM "x" mempty, PC "Contradiction" []) :<=
    [ TC "given" [TC "->" [TM "x" [], TC "False" []],
      TC "prove" [TC "False" []]]
    ]
  ]

data TmR
  = My Tm
  | Our Tm Appl
  | Your Appl
  deriving Show

my :: TmR -> Maybe Tm
my (My t) = Just t
my (Our t _) = Just t
my _ = Nothing

data Status
  = Junk Gripe
  | Keep
  | Need
  deriving (Show, Eq)

data Gripe
  = Surplus
  | Scope String
  | Mardiness
  deriving (Show, Eq)

passive :: Prove () Appl -> Prove Status TmR
passive (Prove g m () ps) = Prove (Your g) (fmap Your m) Keep (map subPassive ps)
subPassive :: ([Given Appl], Prove () Appl) -> ([Given TmR], Prove Status TmR)
subPassive (gs, p) = (map (fmap Your) gs, passive p)

-- this type is highly provisional
chkProof
  :: Setup       -- a big record of gubbins
  -> Context     -- what do we know?
  -> TmR         -- the goal
  -> Method Appl -- the method
  -> [([Given Appl], Prove () Appl)]  -- the subproofs
  -> Prove Status TmR  -- the reconstructed proof

chkProof setup ga g m ps = case my g of
  Just gt -> case m of
    Stub -> Prove
      g Stub Keep (map subPassive ps)
    By r -> case scoApplTm ga r of
      Left x -> Prove
        g (By (Your r)) (Junk (Scope x)) (map subPassive ps)
      Right r@(Our rt _) -> case
        [ stan (mgh ++ mmn) ss
        | ((h, n) :<= ss) <- byRules setup
        , mgh <- mayl $ match mempty h gt
        , mmn <- mayl $ match mempty n rt
        ] of
        [ss] -> Prove g (By r) Keep (chkSubProofs setup ga ss ps)
        _ -> Prove g (By r) (Junk Mardiness) (map subPassive ps)
    From h -> case scoApplTm ga h of
      Left x -> Prove
        g (From (Your h)) (Junk (Scope x)) (map subPassive ps)
      Right h@(Our ht _) -> Prove
        g (From h) Keep
          (chkSubProofs setup ga (fromSubs setup ga gt ht) ps)
  Nothing -> Prove g (fmap Your m) (Junk Mardiness) (map subPassive ps)

-- checking subproofs amounts to validating them,
-- then checking which subgoals are covered,
-- generating stubs for those which are not,
-- and marking as surplus those subproofs which do
-- not form part of the cover
chkSubProofs
  :: Setup
  -> Context                    -- what do we know?
  -> [Tm]                       -- subgoals expected from rule
  -> [([Given Appl], Prove () Appl)]   -- subproofs expected from user
  -> [([Given TmR], Prove Status TmR)] -- reconstruction
chkSubProofs setup ga ss ps = map squish qs ++ extra us where
  (qs, us) = cover ss $ map ((,) False . validSubProof setup ga) ps
  cover [] qs = (qs, [])
  cover (t : ts) qs = case cover1 t qs of
    Nothing -> case cover ts qs of
      (qs, ts) -> (qs, t : ts)
    Just qs -> cover ts qs
  cover1 t [] = Nothing
  cover1 t (q@(_, p) : qs)
    | covers t p = Just ((True, p) : qs)
    | otherwise  = cover1 t qs
  covers t (hs, Prove g m Keep sps) = case (subgoal (ga, t), my g) of
    (Just (ga, p), Just g) -> all (ga `gives`) hs && (g == p)
    _ -> False
  squish (False, (gs, Prove g m Keep ss)) = (gs, Prove g m (Junk Surplus) ss)
  squish (_, q) = q
  extra [] = []
  extra (u : us) = case subgoal (ga, u) of
    Nothing -> extra us
    Just (ga, g)
      | gives ga (Given (My g)) -> extra us
      | otherwise -> need u : extra us
  need (TC "prove" [g]) = ([], Prove (My g) Stub Need [])
  need (TC "given" [h, u]) = case need u of
    (gs, p) -> (Given (My h) : gs, p)

subgoal :: (Context, Tm) -> Maybe (Context, Tm)
subgoal (ga, TC "given" [h, g]) = subgoal (ga :< Hyp h, g)
subgoal (ga, TC "prove" [g]) = Just (ga, g)
subgoal _ = Nothing

gives :: Context -> Given TmR -> Bool
gives ga (Given h) = case my h of
  Just h -> any (Hyp h ==) ga
  Nothing -> False

validSubProof
  :: Setup
  -> Context
  -> ([Given Appl], Prove () Appl)
  -> ([Given TmR], Prove Status TmR)
validSubProof setup ga (Given h : gs, p@(Prove sg sm () sps)) = case scoApplTm ga h of
  Left x -> (map (fmap Your) (Given h : gs),
             Prove (Your sg) (fmap Your sm) (Junk (Scope x)) (map subPassive sps))
  Right h@(Our ht _) -> case validSubProof setup (ga :< Hyp ht) (gs, p) of
    (gs, p) -> (Given h : gs, p)
validSubProof setup ga ([], Prove sg sm () sps) = case scoApplTm ga sg of
  Left x -> ([], Prove  (Your sg) (fmap Your sm) (Junk (Scope x)) (map subPassive sps))
  Right sg -> ([], chkProof setup ga sg sm sps)

fromSubs
  :: Setup
  -> Context
  -> Tm      -- goal
  -> Tm      -- fmla
  -> [Tm]
fromSubs setup ga g f = TC "prove" [f] : case
  [ (n, stan m ss)  -- ignoring n will not always be ok
  | ((h, n) :<= ss) <- introRules setup
  , m <- mayl $ match mempty h f
  ] of
  [(_, [s])] -> flop s g
  rs -> map (foldr wrangle (TC "prove" [g]) . snd) rs
 where
  flop (TC "prove" [p]) g = [TC "given" [p, TC "prove" [g]]]
  flop (TC "given" [h, s]) g = TC "prove" [h] : flop s g
  flop _ _ = [TC "prove" [g]] -- should not happen
  wrangle p g = TC "given" [wangle p, g]
  wangle (TC "given" [s, t]) = TC "->" [s, wangle t]
  wangle (TC "prove" [p]) = p
  wangle _ = TC "True" []


type Context = Bwd CxE

data CxE -- what sort of thing is in the context?
  = Hyp Tm
  | Var String
  deriving (Show, Eq)


applScoTm :: Appl -> (Context, TmR)
applScoTm a = (ga, Our t a) where
  (xs, t) = go a
  ga = B0 <>< map Var (nub xs)
  ge x (ga :< Var y) = if x == y then 0 else 1 + ge x ga
  ge x (ga :< _)     = ge x ga
  go ((t, _, y) :$$ ras) = case t of
      Lid -> (y : ys, TE (foldl (:$) (TV (ge y ga)) ts))
      _   -> (ys, TC y ts)
    where
    (ys, ts) = traverse (go . snd) ras

scoApplTm :: Context -> Appl -> Either String TmR
scoApplTm ga a = (`Our` a) <$> go a
  where
    go ((t, _, y) :$$ ras) = case t of
      Lid -> TE <$> ((foldl (:$) . TV) <$> ge y ga <*> as)
      _   -> TC y <$> as
      where as = traverse (go . snd) ras
    ge x (ga :< Var y) = if x == y then pure 0 else (1 +) <$> ge x ga
    ge x (ga :< _)     = ge x ga
    ge x B0            = Left x

mayl :: Maybe x -> [x]
mayl = foldMap return

filth :: String -> IO ()
filth = mapM_ yuk . raw (fixities mySetup) where
  yuk (RawProof (Prove gr mr () ps), _) =
    print $ chkProof mySetup ga g mr ps where
    (ga, g) = applScoTm gr
  yuk (p, _) = print p