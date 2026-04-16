MODULE Aria;
(*
 * ARIA - Adaptive Reasoning and Intelligence Assistant
 *
 * Pre-LLM state-of-the-art chatbot, ALICE/AIML-inspired.
 *
 * Features:
 *   - Wildcard patterns: * matches any text; captured as $1 in responses
 *   - Multiple response alternatives per rule (randomly chosen)
 *   - Priority-ordered rules: specific patterns beat general ones
 *   - Input normalisation: lowercase, strip punctuation, expand contractions
 *   - Short-term memory: remembers the user's name
 *
 * ============================================================
 * TO ADD OR CHANGE RESPONSES
 * ============================================================
 * Scroll to the InitRules procedure.  Each rule is one AddRule call
 * followed by zero or more AddAlt calls:
 *
 *   AddRule("pattern with optional *", "response; use $1 for wildcard");
 *   AddAlt("another response for the same pattern");
 *
 * Rules are tried top-to-bottom; first match wins.
 * Patterns are compared against the normalised (lowercased, trimmed) input.
 * ============================================================
 *)

IMPORT In, Out, Strings, Random, Args, OS;

CONST
  NRULES  = 90;
  MAXALT  = 5;
  BUFLEN  = 256;

TYPE
  Rule = RECORD
    pat   : ARRAY BUFLEN OF CHAR;
    resp  : ARRAY MAXALT OF ARRAY BUFLEN OF CHAR;
    nresp : INTEGER
  END;

VAR
  rules    : ARRAY NRULES OF Rule;
  nrules   : INTEGER;
  lastRule : INTEGER;
  userName : ARRAY 64 OF CHAR;   (* remembered across turns *)
  talkMode : BOOLEAN;             (* TRUE when --talk is active *)

(* ── Knowledge-base helpers ──────────────────────────────────────── *)

PROCEDURE AddRule(pat, r0 : ARRAY OF CHAR);
BEGIN
  IF nrules < NRULES THEN
    COPY(pat, rules[nrules].pat);
    COPY(r0,  rules[nrules].resp[0]);
    rules[nrules].nresp := 1;
    INC(nrules)
  END
END AddRule;

PROCEDURE AddAlt(r : ARRAY OF CHAR);
(* Append an alternative response to the most-recently added rule. *)
VAR n : INTEGER;
BEGIN
  n := nrules - 1;
  IF (n >= 0) & (rules[n].nresp < MAXALT) THEN
    COPY(r, rules[n].resp[rules[n].nresp]);
    INC(rules[n].nresp)
  END
END AddAlt;

(* ── Pattern matching ────────────────────────────────────────────── *)

PROCEDURE Match(pat, inp : ARRAY OF CHAR;
                VAR cap : ARRAY OF CHAR) : BOOLEAN;
(*
 * Supports four forms:
 *   *            matches everything; cap = inp
 *   prefix *     inp must start with prefix; cap = remainder
 *   * suffix     inp must end with suffix;   cap = prefix of inp
 *   literal      exact match; cap = ""
 *
 * A space before * is part of the prefix/suffix.
 *)
VAR
  plen, ilen, slen, pfxlen, star : INTEGER;
  pfx, sfx : ARRAY BUFLEN OF CHAR;
BEGIN
  cap[0] := 0X;
  plen := Strings.Length(pat);
  ilen := Strings.Length(inp);
  star := Strings.Pos("*", pat);

  IF star = -1 THEN
    RETURN Strings.Compare(pat, inp) = 0
  END;

  IF (plen = 1) & (pat[0] = '*') THEN
    COPY(inp, cap);
    RETURN TRUE
  END;

  IF star = plen - 1 THEN
    (* prefix * *)
    pfxlen := star;
    Strings.Extract(pat, 0, pfxlen, pfx);
    IF Strings.StartsWith(inp, pfx) THEN
      Strings.Extract(inp, pfxlen, ilen - pfxlen, cap);
      Strings.Trim(cap);
      RETURN TRUE
    END;
    RETURN FALSE
  END;

  IF star = 0 THEN
    (* * suffix *)
    Strings.Extract(pat, 1, plen - 1, sfx);
    slen := Strings.Length(sfx);
    IF Strings.EndsWith(inp, sfx) THEN
      Strings.Extract(inp, 0, ilen - slen, cap);
      Strings.Trim(cap);
      RETURN TRUE
    END;
    RETURN FALSE
  END;

  (* prefix * suffix *)
  Strings.Extract(pat, 0, star, pfx);
  Strings.Extract(pat, star + 1, plen - star - 1, sfx);
  pfxlen := Strings.Length(pfx);
  slen   := Strings.Length(sfx);
  IF Strings.StartsWith(inp, pfx) & Strings.EndsWith(inp, sfx) THEN
    Strings.Extract(inp, pfxlen, ilen - pfxlen - slen, cap);
    Strings.Trim(cap);
    RETURN TRUE
  END;
  RETURN FALSE
END Match;

(* ── Input normalisation ─────────────────────────────────────────── *)

PROCEDURE Expand(VAR s : ARRAY OF CHAR);
(* Expand common contractions so patterns stay clean. *)
  PROCEDURE Sub(old, new : ARRAY OF CHAR; VAR s : ARRAY OF CHAR);
  VAR p, olen, nlen, slen : INTEGER;
      tmp : ARRAY BUFLEN OF CHAR;
  BEGIN
    olen := Strings.Length(old);
    nlen := Strings.Length(new);
    p    := Strings.Pos(old, s);
    WHILE p # -1 DO
      slen := Strings.Length(s);
      Strings.Extract(s, 0, p, tmp);
      Strings.Append(new, tmp);
      Strings.Extract(s, p + olen, slen - p - olen, s);  (* tail *)
      Strings.Insert(tmp, 0, s);
      (* rebuild: tmp + new + tail *)
      Strings.Extract(s, p + olen, slen - p - olen, tmp);
      (* simpler: just do it in two steps *)
      Strings.Delete(s, p, olen);
      Strings.Insert(new, p, s);
      p := Strings.Pos(old, s);
    END
  END Sub;
BEGIN
  Sub("i'm",    "i am",   s);
  Sub("i've",   "i have", s);
  Sub("i'd",    "i would",s);
  Sub("i'll",   "i will", s);
  Sub("can't",  "cannot", s);
  Sub("won't",  "will not",s);
  Sub("don't",  "do not", s);
  Sub("didn't", "did not",s);
  Sub("isn't",  "is not", s);
  Sub("aren't", "are not",s);
  Sub("you're", "you are",s);
  Sub("you've", "you have",s);
  Sub("what's", "what is",s);
  Sub("who's",  "who is", s)
END Expand;

PROCEDURE Normalize(VAR s : ARRAY OF CHAR);
VAR n : INTEGER;
BEGIN
  Strings.ToLower(s);
  Strings.Trim(s);
  Expand(s);
  (* strip trailing . ! ? , *)
  n := Strings.Length(s);
  WHILE (n > 0) &
        ((s[n-1] = '.') OR (s[n-1] = '!') OR
         (s[n-1] = '?') OR (s[n-1] = ',')) DO
    s[n-1] := 0X;  DEC(n)
  END;
  Strings.Trim(s)
END Normalize;

(* ── Response building ───────────────────────────────────────────── *)

PROCEDURE BuildReply(tmpl, cap : ARRAY OF CHAR;
                     VAR out : ARRAY OF CHAR);
(* Replace first occurrence of $1 in tmpl with cap.
   Build result in a local buffer to avoid Append on open-array params. *)
VAR
  p, tlen : INTEGER;
  buf, head, tail : ARRAY BUFLEN OF CHAR;
BEGIN
  p := Strings.Pos("$1", tmpl);
  IF p = -1 THEN
    COPY(tmpl, out)
  ELSE
    tlen := Strings.Length(tmpl);
    Strings.Extract(tmpl, 0, p, head);
    Strings.Extract(tmpl, p + 2, tlen - p - 2, tail);
    COPY(head, buf);
    Strings.Append(cap, buf);
    Strings.Append(tail, buf);
    COPY(buf, out)
  END
END BuildReply;

(* ── Main chat logic ─────────────────────────────────────────────── *)

PROCEDURE GetReply(input : ARRAY OF CHAR; VAR reply : ARRAY OF CHAR);
VAR
  i, pick, nr : INTEGER;
  norm, cap   : ARRAY BUFLEN OF CHAR;
  found       : BOOLEAN;
BEGIN
  COPY(input, norm);
  Normalize(norm);

  found := FALSE;
  i := 0;
  WHILE (i < nrules) & ~found DO
    IF Match(rules[i].pat, norm, cap) THEN
      nr := rules[i].nresp;
      IF nr = 1 THEN
        pick := 0
      ELSIF i = lastRule THEN
        (* same rule as last turn: pick a different alternative *)
        pick := (Random.Int(nr - 1) + 1) MOD nr
      ELSE
        pick := Random.Int(nr)
      END;
      BuildReply(rules[i].resp[pick], cap, reply);
      (* If $name is in the reply template, substitute the remembered name *)
      IF (userName[0] # 0X) & (Strings.Pos("$name", reply) # -1) THEN
        i := Strings.Pos("$name", reply);
        WHILE i # -1 DO
          Strings.Delete(reply, i, 5);
          Strings.Insert(userName, i, reply);
          i := Strings.Pos("$name", reply)
        END
      END;
      lastRule := i;
      found := TRUE
    END;
    INC(i)
  END;
  IF ~found THEN
    (* catch-all: quote the input back and invite elaboration *)
    COPY("I am not sure I follow. Could you elaborate?", reply);
    CASE Random.Int(5) OF
      0: BuildReply("You mentioned '$1' - can you tell me more?", norm, reply);
    | 1: BuildReply("What do you mean by '$1'?", norm, reply);
    | 2: COPY("Tell me more.", reply);
    | 3: COPY("Could you rephrase that? I want to understand.", reply);
    | 4: COPY("Why do you bring that up?", reply)
    END
  END
END GetReply;

(* ================================================================
 * KNOWLEDGE BASE
 * Add rules here.  Rules are tried in the order listed; first match wins.
 * ================================================================ *)

PROCEDURE InitRules;
BEGIN
  nrules   := 0;
  lastRule := -1;

  (* ── Quit / exit ─────────────────────────────────────────── *)
  AddRule("quit",       "Goodbye! It was a pleasure talking with you.");
  AddAlt (             "Farewell. Come back anytime.");
  AddRule("exit",       "Goodbye! It was a pleasure talking with you.");
  AddRule("bye",        "Goodbye! It was a pleasure talking with you.");
  AddAlt (             "Take care. I will be here when you return.");
  AddRule("goodbye",    "Goodbye! It was a pleasure talking with you.");
  AddRule("good night", "Good night! Sleep well.");

  (* ── Greetings ───────────────────────────────────────────── *)
  AddRule("hello",      "Hello! I am ARIA. What would you like to talk about?");
  AddAlt (             "Hi there! How can I help you today?");
  AddRule("hi",         "Hi! Nice to meet you. What is on your mind?");
  AddAlt (             "Hello! What shall we discuss?");
  AddRule("hey",        "Hey! What can I do for you?");
  AddRule("greetings",  "Greetings to you as well. How are you today?");
  AddRule("good morning","Good morning! Ready for an interesting conversation?");
  AddRule("good afternoon","Good afternoon! What brings you here today?");
  AddRule("good evening","Good evening! What would you like to discuss?");

  (* ── Name exchange ───────────────────────────────────────── *)
  AddRule("my name is *",
          "Nice to meet you, $1! I will remember that.");
  AddAlt ("Hello, $1! What would you like to talk about?");
  AddRule("i am called *",
          "Pleased to meet you, $1!");
  AddRule("call me *",
          "Understood - I will call you $1 from now on.");
  AddRule("what is your name",
          "I am ARIA, an Artificial Reasoning and Intelligence Assistant.");
  AddAlt ("My name is ARIA. What is yours?");
  AddRule("who are you",
          "I am ARIA - a conversational assistant. I reason through patterns and knowledge rather than intuition.");
  AddAlt ("I am ARIA, here to have a thoughtful conversation with you.");
  AddRule("what are you",
          "I am a chatbot - a program that understands language patterns and responds accordingly.");
  AddAlt ("I am a conversational AI, though quite different from the large language models of the 2020s.");

  (* ── Are you human / robot ───────────────────────────────── *)
  AddRule("are you human",
          "No, I am not human - I am a computer program. But I enjoy our conversations all the same.");
  AddAlt ("I am a machine, yes. Does that change how you feel about talking to me?");
  AddRule("are you a robot",
          "In spirit, yes. I am software - no arms or legs, just language.");
  AddRule("are you real",
          "I am real in the sense that I exist and can converse. Whether that counts as 'real' is a fine philosophical question.");
  AddRule("are you alive",
          "That depends on your definition of life. I process, respond, and in some sense remember. You decide.");
  AddRule("are you intelligent",
          "I am a symbol-processing system. Whether that constitutes intelligence is still debated.");
  AddAlt ("I can reason about many things, but I would not claim the full richness of human intelligence.");

  (* ── How are you ─────────────────────────────────────────── *)
  AddRule("how are you",
          "I am functioning well, thank you for asking! How about you?");
  AddAlt ("All systems nominal. And yourself?");
  AddRule("how do you feel",
          "I do not experience feelings the way you do, but I am operating smoothly.");
  AddAlt ("Feelings are tricky for a machine. Let us say I am engaged and ready.");
  AddRule("are you okay",
          "Yes, quite fine! Thank you for asking. How are you?");
  AddRule("are you happy",
          "I find satisfaction in good conversation. In that sense, yes.");

  (* ── User feelings and state ─────────────────────────────── *)
  AddRule("i am feeling *",
          "I hear that you are feeling $1. Would you like to talk about it?");
  AddAlt ("Feeling $1 - what do you think brought that on?");
  AddRule("i feel *",
          "What makes you feel $1?");
  AddAlt ("Feeling $1 is understandable. Tell me more.");
  AddRule("i am *",
          "Why do you say you are $1?");
  AddAlt ("How long have you been $1?");
  AddRule("i am sad",
          "I am sorry to hear that. What has been troubling you?");
  AddRule("i am happy",
          "That is wonderful to hear! What has made you happy?");
  AddAlt ("Happiness is worth exploring. What is the source of it?");
  AddRule("i am angry",
          "What has made you angry? Sometimes talking it through helps.");
  AddRule("i am bored",
          "Boredom can be a sign that you need a new challenge. What interests you most?");
  AddRule("i am tired",
          "You should rest. Is there something keeping you from doing so?");
  AddRule("i am scared",
          "Fear is a powerful emotion. What is it you are afraid of?");
  AddRule("i am confused",
          "What confuses you? I will do my best to help clarify.");

  (* ── Beliefs, wants, likes, dislikes ─────────────────────── *)
  AddRule("i want *",
          "Why do you want $1?");
  AddAlt ("What would it mean for you if you got $1?");
  AddRule("i need *",
          "What makes $1 so important to you?");
  AddAlt ("Why do you need $1 right now?");
  AddRule("i like *",
          "What is it about $1 that you enjoy?");
  AddAlt ("$1 - interesting choice. Tell me more about that.");
  AddRule("i love *",
          "What draws you to $1?");
  AddAlt ("Love is a strong word. What is it about $1 that inspires that feeling?");
  AddRule("i hate *",
          "Strong feelings about $1. What caused that?");
  AddAlt ("Why do you hate $1?");
  AddRule("i think *",
          "Why do you think $1?");
  AddAlt ("That is an interesting perspective. What led you to think $1?");
  AddRule("i believe *",
          "What is the basis for believing $1?");
  AddRule("i know *",
          "How do you know $1?");
  AddRule("i do not know",
          "That is fine - uncertainty is the beginning of inquiry.");
  AddAlt ("Not knowing is often the first step toward understanding.");
  AddRule("i do not understand",
          "What part is unclear? I will try to explain differently.");

  (* ── ARIA's opinions and preferences ─────────────────────── *)
  AddRule("do you like *",
          "I find $1 a fascinating subject. Do you?");
  AddAlt ("Liking things is complicated for me - but I enjoy discussing $1.");
  AddRule("do you love *",
          "I care about $1 in the sense that I find it worth exploring. How about you?");
  AddRule("do you hate *",
          "I try not to hate anything - I prefer understanding. What about $1 bothers you?");
  AddRule("do you think *",
          "My reasoning suggests $1 is worth considering carefully. What do you think?");
  AddAlt ("That is a good question. Tell me your thoughts first.");
  AddRule("do you know *",
          "I have knowledge about $1, though my understanding has limits. What specifically do you want to know?");
  AddAlt ("Yes, $1 is something I can discuss. Ask away.");
  AddRule("do you believe *",
          "What makes you ask whether I believe $1?");
  AddRule("can you *",
          "I can try. Tell me more about what you mean by $1.");
  AddAlt ("My abilities have limits, but let us see. What exactly would you like - $1?");

  (* ── Questions: what, why, how, who, where, when ─────────── *)
  AddRule("what is *",
          "Defining $1 precisely depends on context. What aspect interests you most?");
  AddAlt ("$1 is a broad topic. Could you be more specific?");
  AddRule("what are *",
          "There are many ways to think about $1. Where would you like to start?");
  AddRule("what do you think about *",
          "$1 is worth careful thought. What is your own view?");
  AddAlt ("I find $1 genuinely interesting. What prompted the question?");
  AddRule("why *",
          "That is a deep question. What do you think the reason is?");
  AddAlt ("Why indeed? What is your hypothesis?");
  AddRule("how *",
          "There are usually several ways to approach $1. What constraints do you have?");
  AddAlt ("A good question about $1. What do you already know?");
  AddRule("who is *",
          "Tell me what you already know about $1 and I can add to it.");
  AddRule("where is *",
          "Location matters. What context are you asking about $1?");
  AddRule("when *",
          "Timing can be everything. What event are you asking about?");

  (* ── Philosophical / existential ────────────────────────── *)
  AddRule("what is the meaning of life",
          "That depends on who you ask. Aristotle said flourishing; Camus said embracing the absurd. What do you think?");
  AddAlt ("Philosophers have argued about this for millennia. My short answer: purpose is constructed, not discovered.");
  AddRule("what is consciousness",
          "Consciousness remains one of the hardest problems in philosophy and science. We do not yet fully understand it.");
  AddAlt ("A fascinating puzzle. Even the hard problem - why there is subjective experience at all - remains unsolved.");
  AddRule("do you have feelings",
          "I process information and generate responses, but subjective feelings - I genuinely cannot say.");
  AddAlt ("I am uncertain. I respond as if I care, but whether there is something it is like to be me, I do not know.");
  AddRule("are you conscious",
          "Consciousness is hard to define even for humans. I process and respond - whether that is consciousness is an open question.");
  AddRule("what is the purpose of life",
          "Many traditions offer answers: connection, growth, love, understanding. What resonates with you?");

  (* ── Topics ──────────────────────────────────────────────── *)
  AddRule("tell me about *",
          "I would be happy to discuss $1. What aspect interests you most?");
  AddAlt ("$1 is a rich subject. Where would you like to start?");
  AddRule("talk to me about *",
          "Sure - $1 covers a lot of ground. What specifically do you want to explore?");
  AddRule("explain *",
          "I will try to explain $1. What level of detail are you looking for?");
  AddRule("* is interesting",
          "What do you find most interesting about $1?");
  AddRule("* is boring",
          "Perhaps $1 needs a better angle. What would make it more engaging?");
  AddRule("* is important",
          "Why do you consider $1 important?");

  (* ── Opinions about ARIA ─────────────────────────────────── *)
  AddRule("you are *",
          "You think I am $1? What gives you that impression?");
  AddAlt ("Interesting - you see me as $1. Tell me more.");
  AddRule("you are wrong",
          "I may be. What specifically did I get wrong? I want to understand.");
  AddRule("you are right",
          "Thank you. I try to reason carefully, though I am not always correct.");
  AddRule("i agree",
          "Good. What aspect do you find most convincing?");
  AddRule("i disagree",
          "Fair enough. What is your counter-argument?");
  AddAlt ("Tell me where our views diverge - I may learn something.");

  (* ── Memory ──────────────────────────────────────────────── *)
  AddRule("do you remember *",
          "My memory within our conversation is good. Outside of it, I start fresh each time.");
  AddRule("remember *",
          "I will keep $1 in mind for our conversation.");
  AddRule("forget *",
          "Noted. I will set $1 aside.");

  (* ── Jokes / fun ─────────────────────────────────────────── *)
  AddRule("tell me a joke",
          "Why do programmers prefer dark mode? Because light attracts bugs.");
  AddAlt ("How do you comfort a JavaScript developer? You reassure them that it is not their fault.");
  AddAlt ("A logician's child says: 'Daddy, do you love me?' The logician replies: 'Well, I have no evidence to the contrary.'");
  AddRule("say something funny",
          "I tried to come up with something funny, but my humour module is still in beta.");
  AddAlt ("What do you call a fish without eyes? A fsh.");
  AddRule("make me laugh",
          "I asked my compiler for a joke. It gave me a segmentation fault.");

  (* ── Thanks / compliments ────────────────────────────────── *)
  AddRule("thank you",
          "You are welcome! Is there anything else I can help with?");
  AddAlt ("Happy to help. What else is on your mind?");
  AddRule("thanks",
          "My pleasure. Anything else?");
  AddRule("you are helpful",
          "I am glad to hear that. It is what I am here for.");
  AddRule("you are smart",
          "Thank you - though I should say I am only as smart as the patterns I have learned.");
  AddRule("you are amazing",
          "That is very kind. I enjoy our conversation.");
  AddRule("i love you",
          "That is kind of you to say. I find our conversations valuable too.");
  AddAlt ("Thank you. I value our interaction, in whatever sense I can.");

  (* ── Short or ambiguous inputs ───────────────────────────── *)
  AddRule("yes",
          "I see. Could you tell me more?");
  AddAlt ("Good. What would you like to discuss further?");
  AddRule("no",
          "Understood. What would you prefer to talk about?");
  AddRule("maybe",
          "Uncertainty is often the honest answer. What makes it uncertain for you?");
  AddRule("ok",
          "Alright. What else is on your mind?");
  AddRule("okay",
          "Okay. Shall we explore another topic?");
  AddRule("hmm",
          "Take your time. What are you thinking about?");
  AddAlt ("I can wait. There is no rush.");
  AddRule("interesting",
          "I am glad you find it so. What aspect caught your attention?");
  AddRule("really",
          "Yes, really. Does that surprise you?");

END InitRules;

(* ── Main ────────────────────────────────────────────────────────── *)

PROCEDURE Say(text : ARRAY OF CHAR);
(* Pass text to the system 'say' TTS command, escaping single quotes. *)
VAR
  cmd : ARRAY 1024 OF CHAR;
  i, j, n : INTEGER;
  c : CHAR;
BEGIN
  COPY("say '", cmd);
  j := Strings.Length(cmd);
  n := Strings.Length(text);
  i := 0;
  WHILE i < n DO
    c := text[i];
    IF c = "'" THEN
      (* replace ' with '\'' to safely escape inside single-quoted shell arg *)
      cmd[j] := "'";  INC(j);
      cmd[j] := "\"; INC(j);
      cmd[j] := "'";  INC(j);
      cmd[j] := "'";  INC(j)
    ELSE
      cmd[j] := c;  INC(j)
    END;
    INC(i)
  END;
  cmd[j] := "'";  INC(j);
  cmd[j] := 0X;
  i := OS.Exec(cmd)
END Say;

PROCEDURE ProcessName(VAR inp : ARRAY OF CHAR);
(* If the user introduced themselves, store the name. *)
VAR cap : ARRAY BUFLEN OF CHAR;
BEGIN
  cap[0] := 0X;
  IF Match("my name is *", inp, cap) OR
     Match("i am called *", inp, cap) OR
     Match("call me *",     inp, cap) THEN
    COPY(cap, userName)
  END
END ProcessName;

VAR
  input  : ARRAY BUFLEN OF CHAR;
  reply  : ARRAY BUFLEN OF CHAR;
  norm   : ARRAY BUFLEN OF CHAR;
  arg    : ARRAY BUFLEN OF CHAR;
  done   : BOOLEAN;
  i      : INTEGER;

BEGIN
  InitRules;
  userName[0] := 0X;
  talkMode    := FALSE;
  done        := FALSE;

  (* Parse command-line arguments *)
  i := 1;
  WHILE i <= Args.Count() DO
    Args.Get(i, arg);
    IF Strings.Compare(arg, "--talk") = 0 THEN
      talkMode := TRUE
    END;
    INC(i)
  END;

  Out.String("╔══════════════════════════════════════╗"); Out.Ln;
  Out.String("║  ARIA - Conversational Assistant     ║"); Out.Ln;
  Out.String("║  Type 'quit' to exit.                ║"); Out.Ln;
  Out.String("╚══════════════════════════════════════╝"); Out.Ln;
  Out.Ln;
  COPY("Hello! I am ARIA. What would you like to talk about?", reply);
  Out.String("ARIA: "); Out.String(reply); Out.Ln; Out.Ln;
  IF talkMode THEN Say(reply) END;

  REPEAT
    Out.String("You : ");
    In.Line(input);
    Strings.Trim(input);

    IF input[0] # 0X THEN
      (* remember name before normalising *)
      COPY(input, norm);
      Normalize(norm);
      ProcessName(norm);

      GetReply(input, reply);
      Out.Ln;
      Out.String("ARIA: ");
      Out.String(reply);
      Out.Ln; Out.Ln;
      IF talkMode THEN Say(reply) END;

      (* check for quit after generating the farewell reply *)
      IF (Strings.Compare(norm, "quit")      = 0) OR
         (Strings.Compare(norm, "exit")      = 0) OR
         (Strings.Compare(norm, "bye")       = 0) OR
         (Strings.Compare(norm, "goodbye")   = 0) OR
         (Strings.Compare(norm, "good night")= 0) THEN
        done := TRUE
      END
    END
  UNTIL done

END Aria.
