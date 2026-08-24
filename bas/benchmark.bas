10 defn fib(n)
20 if n < 2 then return n
30 return fib(n-1) + fib(n-2)
40 endfn
50 t0 = timer
60 r = fib(28)
70 t1 = timer
480 print t1 - t0