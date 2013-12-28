{-# LANGUAGE ScopedTypeVariables #-}
module Graphics.Rasterific.Bezier
    ( Bezier( .. )
    , CubicBezier( .. )
    , clipBezier
    , straightLine
    , cubicBezierCircle
    , strokizeBezierPath
    ) where

import Prelude hiding( or )
import Control.Applicative( (<$>), Applicative, pure )
import Linear( V2( .. )
             , (^-^)
             , (^+^)
             , (^*)
             , dot
             , norm
             )
import Data.Monoid( Monoid( mempty ), (<>) )
import Data.Foldable( Foldable, foldMap )
import Graphics.Rasterific.Operators
import Graphics.Rasterific.Types

{-import Debug.Trace-}
{-import Text.Printf-}

data Bezier = Bezier !Point !Point !Point
  deriving Show

reverseBezier :: Bezier -> Bezier
reverseBezier (Bezier a b c) = Bezier c b a

data CubicBezier = CubicBezier !Point !Point !Point !Point
    deriving Show

cubicBezierCircle :: [CubicBezier]
cubicBezierCircle =
    [ CubicBezier (V2 0 1) (V2 c 1) (V2 1 c) (V2 1 0)
    , CubicBezier (V2 1 0) (V2 1 (-c)) (V2 c (-1)) (V2 0 (-1))
    , CubicBezier (V2 0 (-1)) (V2 (-c) (-1)) (V2 (-1) (-c)) (V2 (-1) 0)
    , CubicBezier (V2 (-1) 0) (V2 (-1) c) (V2 (-c) 1) (V2 0 1)
    ]
  where c = 0.551915024494 -- magic constant? magic constant.

straightLine :: Point -> Point -> Bezier
straightLine a c = Bezier a (a `midPoint` c) c

-- | Clamp the bezier curve inside a rectangle
-- given in parameter.
clipBezier :: (Applicative a, Monoid (a Bezier))
           => Point -> Point -> Bezier -> a Bezier
clipBezier mini maxi bezier@(Bezier a b c)
    -- If we are in the range bound, return the curve
    -- unaltered
    | insideX && insideY = pure bezier
    -- If one of the component is outside, clamp
    -- the components on the boundaries and output a
    -- straight line on this boundary. Useful for the
    -- filing case, to clamp the polygon drawing on
    -- the edge
    | outsideX || outsideY =
        pure $ clampedA `straightLine` clampedC
    -- Not completly inside nor outside, just divide
    -- and conquer.
    | otherwise =
        recurse (Bezier m (b `midPoint`c) c) <>
            recurse (Bezier a (a `midPoint` b) m)
  where -- Minimal & maximal dimension of the bezier curve
        bmin = vmin a $ vmin b c
        bmax = vmax a $ vmax b c

        recurse = clipBezier mini maxi

        clamper = clampPoint mini maxi
        clampedA = clamper a
        clampedC = clamper c

        V2 insideX insideY = mini ^<=^ bmin ^&&^ bmax ^<=^ maxi
        V2 outsideX outsideY = bmax ^<=^ mini ^||^ maxi ^<=^ bmin

        abbc = (a `midPoint` b) `midPoint` (b `midPoint` c)
        edgeSeparator = vabs (abbc ^-^ mini) ^<^ vabs (abbc ^-^ maxi)
        edge = vpartition edgeSeparator mini maxi
        m = vpartition (vabs (abbc ^-^ edge) ^< 0.1) edge abbc

joinBeziers :: (Applicative a, Monoid (a Bezier))
            => Float -> Join -> Bezier -> Bezier -> a Bezier
joinBeziers offset join (Bezier _ ib ic) (Bezier ja jb _) =
  case join of
    JoinRound -> roundJoin offset ic u v
    JoinMiter l -> miterJoin offset l ic u v
  where u = ib `normal` ic
        v = ja `normal` jb

capBezier :: (Applicative a, Monoid (a Bezier))
          => Float -> Cap -> Bezier -> a Bezier
capBezier offset CapRound (Bezier _ b c) = 
  roundJoin offset c u (- u) where u = b `normal` c
capBezier offset (CapStraight cVal) (Bezier _ b c) = 
   pure (d `straightLine` e) <> pure (e `straightLine` f)
                             <> pure (f `straightLine` g)
  where u@(V2 ux uy) = b `normal` c
        v = V2 uy $ negate ux

        e = d ^+^ v ^* (offset * cVal)
        f = g ^+^ v ^* (offset * cVal)
        d = c ^+^ u ^* offset
        g = c ^-^ u ^* offset

miterJoin :: (Applicative a, Monoid (a Bezier))
          => Float -> Float -> Point -> Vector -> Vector -> a Bezier
miterJoin offset l point u v
  | u `dot` w >= l / max 1 l =
      pure (m `straightLine` c) <> pure (a `straightLine` m)
  | otherwise = pure $ a `straightLine` c
  where a = point ^+^ u ^* offset
        c = point ^+^ v ^* offset
        w = (a `normal` c) `ifZero` u
        p = offset / (u `dot` w)
        m = point + w ^* p

roundJoin :: (Applicative a, Monoid (a Bezier))
          => Float -> Point -> Vector -> Vector -> a Bezier
roundJoin offset p = go
  where go u v
          | u `dot` w >= 0.9 = pure $ Bezier a b c
          | otherwise = go w v <> go u w
          where a = p ^+^ u ^* offset
                c = p ^+^ v ^* offset
                n = p ^+^ w ^* offset
                b = n ^* 2 ^-^ (a `midPoint` c)
                w = (a `normal` c) `ifZero` u

offsetAndJoin :: Float -> Join -> Cap -> [Bezier]
              -> [Bezier]
offsetAndJoin _ _ _ [] = []
offsetAndJoin offset join  caping (firstBezier@(Bezier la _ _):rest) =
    go firstBezier rest
  where joiner = joinBeziers offset join
        offseter = offsetBezier offset
        caper = capBezier offset caping

        go prev@(Bezier _ _ cp) []
           | la == cp = joiner prev firstBezier <> offseter prev
           | otherwise = caper prev <> offseter prev
        go prev (x:xs) =
            go x xs <> joiner prev x <> offseter prev

-- | Rewrite the bezier curve to avoid degenerate cases.
sanitizeBezier :: (Applicative a, Monoid (a Bezier))
               => Bezier -> a Bezier
sanitizeBezier bezier@(Bezier a b c)
   -- If the two normals vector are far apart (cos nearly -1)
   --
   --       u           v
   -- <----------   ------------>
   -- because u dot v = ||u|| * ||v|| * cos(uv)
   --
   -- This imply that AB and BC are nearly parallel
   | u `dot` v < -0.9999 =
     -- divide in to halves with
     sanitizeBezier (Bezier abbc (abbc `midPoint` c) c) <>
        sanitizeBezier (Bezier a (a `midPoint` abbc) abbc)

   -- b is far enough of b and c, (it's not a point)
   | norm (a ^-^ b) > 0.0001 && norm (b ^-^ c) > 0.0001 =
       pure bezier

   -- if b is to nearby a or c, take the midpoint as new reference.
   | ac /= b = sanitizeBezier (Bezier a ac c)
   | otherwise = mempty
  where u = a `normal` b
        v = b `normal` c
        ac = a `midPoint` c
        abbc = (a `midPoint` b) `midPoint` (b `midPoint` c)

offsetBezier :: (Applicative a, Monoid (a Bezier))
             => Float -> Bezier -> a Bezier
offsetBezier offset (Bezier a b c)
    -- If the spline is not too curvy, just return the
    -- shifted component
    | u `dot` v >= 0.9 =
        pure $ Bezier shiftedA mergedB shiftedC
    -- Otherwise, divide and conquer
    | a /= b && b /= c =
        offsetBezier offset (Bezier abbc bc c) <>
            offsetBezier offset (Bezier a ab abbc)
    | otherwise = mempty
  where --
        --         X B   
        --    ^   /^\   ^
        --   u \ /w| \ / v
        --      X-----X
        --     /       \
        --    /         \
        -- A X           X C
        --
        u = a `normal` b
        v = b `normal` c
        w = ab `normal` bc

        ab = (a `midPoint` b)
        bc = (b `midPoint` c)
        abbc = ab `midPoint` bc

        shiftedA = a ^+^ (u ^* offset)
        shiftedC = c ^+^ (v ^* offset)
        shiftedABBC = abbc ^+^ (w ^* offset)
        mergedB =
            (shiftedABBC ^* 2.0) ^-^ (shiftedA `midPoint` shiftedC)

-- | Transform a bezier path to a bezier shape ready
-- to be filled
strokizeBezierPath :: Float -> Join -> (Cap, Cap) -> [Bezier]
                   -> [Bezier]
strokizeBezierPath width join (capStart, capEnd) beziers =
    offseter capEnd sanitized <> 
        offseter capStart (reverse $ reverseBezier <$> sanitized)
  where sanitized = foldMap sanitizeBezier beziers
        offseter = offsetAndJoin (width / 2) join

