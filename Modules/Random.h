#ifndef OBC_RANDOM_H_
#define OBC_RANDOM_H_

/* Random.Int(n)  — uniform integer in [0, n) */
int    Random_Int(int n);

/* Random.Real()  — uniform double in [0.0, 1.0) */
double Random_Real(void);

/* Random.Randomize()  — reseed from a high-resolution time source */
void   Random_Randomize(void);

/* Random.Seed(n)  — reseed explicitly, for a reproducible sequence */
void   Random_Seed(int n);

#endif /* OBC_RANDOM_H_ */
