#ifndef OBC_PARALLEL_H_
#define OBC_PARALLEL_H_

typedef void (*Parallel_BodyFn)(int);

int  Parallel_NumCPU(void);
void Parallel_For(int lo, int hi, Parallel_BodyFn body, int nthreads);

#endif /* OBC_PARALLEL_H_ */
