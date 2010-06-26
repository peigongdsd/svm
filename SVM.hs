{-# OPTIONS_GHC -XBangPatterns #-}

-- This module performs support vector regression on a set of training points in order to determine the
-- generating function.  Currently least squares support vector regression is implemented.  The optimal
-- solution to the Langrangian is found by a conjugate gradient algorithm (CGA).  The CGA finds the
-- saddle point of the dual of the Lagrangian.
module SVM (DataSet (..), SVMSolution (..), KernelFunction (..), SVM (..), LSSVM (..), KernelMatrix (..),
            reciprocalKernelFunction, radialKernelFunction, linearKernelFunction, splineKernelFunction,
            polyKernelFunction, mlpKernelFunction, projectSVMSolution) where
   
   import Data.Array.Unboxed             -- Unboxed arrays are used for better performance.
   import Data.List (foldl')             -- foldl' gives better performance than sum

   -- Each data set is a list of vectors (the points) and a corresponding list of values.
   data DataSet = DataSet {points::(Array Int [Double]), values::(UArray Int Double)}
   
   -- The solution contains the dual weights, the support vectors and the bias.
   data SVMSolution = SVMSolution {alpha::(UArray Int Double), sv::(Array Int [Double]), bias::Double}
   
   -- The kernel matrix has been implemented as an unboxed array for performance reasons.
   newtype KernelMatrix = KernelMatrix (UArray Int Double)
   
   -- Every kernel function represents an inner product in feature space. The third list is a set of parameters.
   newtype KernelFunction = KernelFunction ([Double] -> [Double] -> [Double] -> Double)
   
   -- Some common kernel functions (these are called many times, so they need to be fast):
   
   -- The reciprocal kernel is the result of exponential basis functions, exp(-k*(x+a)).  The inner product
   -- is an integral over all k >= 0.
   reciprocalKernelFunction :: [Double] -> [Double] -> [Double] -> Double
   reciprocalKernelFunction (a:as) (x:xs) (y:ys) = (1 / (x + y + 2*a)) * reciprocalKernelFunction as xs ys
   reciprocalKernelFunction _ _ _ = 1
   
   -- This is the kernel when radial basis functions are used.
   radialKernelFunction :: [Double] -> [Double] -> [Double] -> Double
   radialKernelFunction (a:as) x y = exp $ (cpshelp 0 x y) / a
            where cpshelp !accum (x:xs) (y:ys) = cpshelp (accum + (x-y)**2) xs ys
                  cpshelp !accum _ _ = negate accum
   
   -- This is a simple dot product between the two data points, corresponding to a featurless space.
   linearKernelFunction :: [Double] -> [Double] -> [Double] -> Double
   linearKernelFunction (a:as) (x:xs) (y:ys) = x * y + linearKernelFunction as xs ys
   linearKernelFunction _ _ _ = 0
   
   splineKernelFunction :: [Double] -> [Double] -> [Double] -> Double
   splineKernelFunction a x y | dp <= 1.0 = (2/3) - dp^2 + (0.5*dp^3)
                              | dp <= 2.0 = (1/6) * (2-dp)^3
                              | otherwise = 0.0
            where dp = linearKernelFunction a x y
   
   polyKernelFunction :: [Double] -> [Double] -> [Double] -> Double
   polyKernelFunction (a0:a1:as) x y = (a0 + linearKernelFunction as x y)**a1
   
   mlpKernelFunction :: [Double] -> [Double] -> [Double] -> Double
   mlpKernelFunction (a0:a1:as) x y = tanh (a0 * linearKernelFunction as x y - a1)
   
   -- A support vector machine (SVM) can estimate a function based upon some training data.  Instances of this
   -- class need only implement the dual cost and the kernel function.  Default implementations are given
   -- for finding the SVM solution, for simulating a function and for creating a kernel matrix from a set of
   -- training points.  All SVMs should return a solution which contains a list of the support vectors and their
   -- dual weigths.  dcost represents the coefficient of the dual cost function.  This term gets added to the
   -- diagonal elements of the kernel matrix and may be different for each type of SVM.
   class SVM a where
      createKernelMatrix  :: a -> (Array Int [Double]) -> KernelMatrix
      dcost               :: a -> Double
      evalKernel          :: a -> [Double] -> [Double] -> Double
      simulate            :: a -> SVMSolution -> (Array Int [Double]) -> [Double]
      solve               :: a -> DataSet -> Double -> Int -> SVMSolution
      
      -- The kernel matrix is created by evaluating the kernel function on all of the points in the data set.
      -- K[i,j] = f x[i] x[j], so K is symmetric and positive semi-definite.  Only the bottom half is created.
      -- The diagonal elements all have gamma added to them as part of solving the problem.
      createKernelMatrix a x = KernelMatrix matrix
               where matrix = listArray (1, dim) [eval i j | j <- indices x, i <- range(1,j)]
                     dim = ((n+1) * n) `quot` 2
                     eval i j | (i /= j) = evalKernel a (x!i) (x!j)
                              | otherwise = evalKernel a (x!i) (x!j) + dcost a
                     n = snd $ bounds x
      
      -- This function takes a set of points and an SVMSolution, representing a function, and evaluates
      -- that function over all of the given points.  A list of the values y = f(x) are returned.
      simulate a (SVMSolution alpha sv b) points = [(eval p) + b | p <- elems points]
               where eval x = mDot alpha $ kfVals x
                     kfVals x = listArray (bounds sv) [evalKernel a x v | v <- elems sv]
      
      -- This function takes a set of points and creates an SVM solution to the problem.  The default
      -- implementation uses a conjugate gradient algorithm to solve for the optimal solution to the
      -- problem.
      solve svm (DataSet points values) epsilon maxIter = SVMSolution alpha points b
		where b = (mDot nu values) / (foldl' (+) 0 $ elems nu)
		      alpha = mZipWith (\x y -> x - b*y) v nu
		      nu = cga startx ones ones kernel epsilon maxIter
		      v = cga startx values values kernel epsilon maxIter
		      ones = listArray (1, n) $ replicate n 1
		      startx = listArray (1, n) $ replicate n 0
		      n = snd $ bounds values
		      kernel = createKernelMatrix svm points
   
   -- A least squares support vector machine.  The cost represents the relative expense of missing a training
   -- versus a more complicated generating function.  The higher this number the better the fit of the training
   -- set, but at a cost of poorer generalization.  The LSSVM uses every training point in the solution and
   -- performs least squares regression on the dual of the problem.
   data LSSVM = LSSVM {kf::KernelFunction, cost::Double, params::[Double]}
 
   instance SVM LSSVM where
      dcost = (0.5 /) . cost
      evalKernel (LSSVM (KernelFunction kf) _ params) = kf params
   
   -- The conjugate gradient algorithm is used to find the optimal solution.  It will run until a cutoff delta
   -- is reached or for a max number of iterations.  The type synonym is just there to shorten the type signature.
   type CGArray = UArray Int Double
   cga :: CGArray -> CGArray -> CGArray -> KernelMatrix -> Double -> Int -> CGArray
   cga x p r k epsilon max_iter = cgahelp x p r norm max_iter False
            where norm = mDot r r
                  cgahelp x _ _ _ _ True = x
                  cgahelp x p r delta iter _ = cgahelp next_x next_p next_r next_delta (iter-1) stop
                           where stop = (next_delta < epsilon * norm) || (iter == 0)
                                 next_x = mAdd x $ scalarmult alpha p
                                 next_p = mAdd next_r $ scalarmult (next_delta/delta) p
                                 next_r = mAdd r $ scalarmult (negate alpha) vector
                                 vector = matmult k p
                                 next_delta = mDot next_r next_r
                                 alpha = delta / (mDot p vector)
   
   -- This function can be used to project the cga solution onto the plane defined by |1>.  This ensures
   -- that the sum of the dual weights vanishes.  The cga is not limited to this plane, although it
   -- assumes it is in its solution for the bias.
   projectSVMSolution :: SVMSolution -> SVMSolution
   projectSVMSolution (SVMSolution alpha sv b) = SVMSolution new_alpha sv b
            where new_alpha = listArray (a, n) [e - num | e <- elems alpha]
                  (a, n) = bounds alpha
                  num = (sum $ elems alpha) / (fromIntegral n)
   
   -- The following functions are used internally for all of the linear algebra involving kernel matrices or
   -- unboxed arrays of doubles (representing vectors).
   
   -- Matrix multiplication between a kernel matrix and a vector is handled by this funciton.  Only the bottom
   -- half of the matrix is stored.  This function requires 1 based indices for both of its arguments.
   matmult :: KernelMatrix -> (UArray Int Double) -> (UArray Int Double)
   matmult (KernelMatrix k) v = listArray (1, d) $ helper 1 1
            where d = snd $ bounds v
                  helper i pos | (i < d) = cpsdot 0 1 pos : helper (i+1) (pos+i)
                               | otherwise = [cpsdot 0 1 pos]
                           where cpsdot acc j n | (j < i) = cpsdot (acc + k!n * v!j) (j+1) (n+1)
                                                | (j < d) = cpsdot (acc + k!n * v!j) (j+1) (n+j)
                                                | otherwise = acc + k!n * v!j
   
   -- This funciton performs scalar multiplication of a vector.
   scalarmult :: Double -> (UArray Int Double) -> (UArray Int Double)
   scalarmult = amap . (*)
   
   -- This function is a version of zipWith for use with unboxed arrays.
   mZipWith :: (Double -> Double -> Double) -> (UArray Int Double) -> (UArray Int Double) -> (UArray Int Double)
   mZipWith f v1 v2 = array (bounds v1) [(i, f (v1!i) (v2!i)) | i <- indices v1]
   
   -- This function takes the standard dot product of two unboxed arrays.
   mDot :: (UArray Int Double) -> (UArray Int Double) -> Double
   mDot = ((foldl' (+) 0 . elems) .) . mZipWith (*)

   mAdd :: (UArray Int Double) -> (UArray Int Double) -> (UArray Int Double)
   mAdd = mZipWith (+)
