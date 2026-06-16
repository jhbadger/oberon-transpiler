This document describes "Cloj," a programming language inspired by Clojure, implemented in a Pascal-like language (likely Oberon). It functions as a REPL (Read-Eval-Print Loop) and can execute script files.

### Core Language Features

*   **Dynamic Typing**: The language is dynamically typed.
*   **Data Types**: It supports a rich set of data types similar to Clojure:
    *   **Primitives**: `Nil`, `Boolean`, `Integer`, `Real`, `BigInt`, `String`, `Symbol`, `Keyword`, and `Regex`.
    *   **Collections**: `List` (linked lists), `Vector` (array-like), `Map` (hash maps), and `Set` (including sorted sets).
    *   **Functions**: First-class functions (`fn`), macros (`macro`), and built-in functions.
    *   **Concurrency/State**: `Atom` for managing shared state, `Delay` and `Promise` for lazy evaluation and asynchronous operations.
*   **Immutability**: The core data structures (lists, vectors, maps, sets) are treated as immutable, with functions like `conj` and `assoc` returning new collections instead of modifying existing ones.
*   **Lisp-like Syntax**: The language uses s-expressions (parenthesized notation), where the first element of a list is typically a function or macro to be executed.
*   **Macros**: Full support for macros (`defmacro`) allows for compile-time code transformation, enabling powerful syntactic abstraction.
*   **Namespaces**: The `ns` special form allows for code organization into different namespaces, similar to Clojure.
*   **Special Forms**: It has a comprehensive set of special forms for control flow and definitions, including `if`, `let`, `do`, `fn`, `def`, `loop`/`recur`, and `try`/`catch`.
*   **Protocols and Records**: `defrecord` and `defprotocol` provide a way to define custom data types and implement polymorphic behavior, akin to Clojure's protocols.
*   **BigInt Arithmetic**: The language has built-in support for arbitrary-precision integers (`BigInt`).

### Built-in Functions

The language comes with a large standard library of built-in functions, many of which are direct counterparts to those in Clojure. Below is a categorized summary:

#### Arithmetic & Math
- **Basic Operations**: `+`, `-`, `*`, `/`, `mod`, `quot`, `rem`, `inc`, `dec`
- **Comparison**: `<`, `>`, `<=`, `>=`, `=`, `not=`
- **Numeric Properties**: `abs`, `even?`, `odd?`, `zero?`, `pos?`, `neg?`
- **Advanced Math**: `sqrt`, `floor`, `ceil`, `round`, `pow`, `log`, `exp`, `sin`, `cos`, `tan`
- **Randomness**: `rand`, `rand-int`

#### Sequence & Collection Manipulation
- **Constructors**: `list`, `vector`, `vec`, `hash-map`, `set`, `sorted-set`, `range`
- **Accessors**: `first`, `second`, `last`, `rest`, `next`, `nth`, `get`
- **Modification**: `cons`, `conj`, `assoc`, `dissoc`, `merge`, `into`
- **Transformation**: `map`, `map-indexed`, `filter`, `reduce`, `take`, `drop`, `sort`, `reverse`
- **Higher-Order Functions**: `apply`, `partial`, `comp`, `every?`, `some`, `remove`
- **Utilities**: `count`, `empty?`, `concat`, `distinct`, `flatten`

#### String Operations
- `str`, `subs`, `split`, `join`, `upper-case`, `lower-case`, `trim`, `starts-with?`, `ends-with?`, `string/reverse`

#### Type & Value Predicates
- `nil?`, `true?`, `false?`, `boolean?`, `number?`, `string?`, `keyword?`, `symbol?`, `fn?`, `coll?`, `seq?`, `map?`, `vector?`

#### State & Concurrency
- `atom`, `atom?`, `deref` (or `@`), `reset!`, `swap!`
- `delay`, `force`, `promise`, `deliver`

#### I/O
- `prn`, `println`, `pr`, `print`, `newline`, `read-string`, `load-file`

#### Miscellaneous
- `identity`, `gensym`, `name`, `keyword`, `symbol`, `type`

This implementation provides a robust, Clojure-like environment with a focus on functional programming principles, immutable data structures, and powerful metaprogramming capabilities.

Is there a specific feature or function you would like to explore in more detail?