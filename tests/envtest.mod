MODULE EnvTest;

IMPORT Env, Out;

VAR env: ARRAY 1024 OF CHAR;

BEGIN
  Env.Get("PATH", env);
  Out.String(env);
  Out.Ln;
END EnvTest.