# Elixir Code Smells & Refactorings — Reference for Claude Code

Condensed from Lucas Vegi's PhD thesis *"Code Smells and Refactorings for Elixir"* (Vegi & Valente, UFMG). Source catalogs: <https://github.com/lucasvegi/Elixir-Code-Smells> and <https://github.com/lucasvegi/Elixir-Refactorings>.

## How to use this file

When writing, reviewing, or refactoring Elixir in this project:

- Treat the smells below as review heuristics, not hard rules. Flag an instance only when it genuinely hurts readability, testability, or correctness — idiomatic exceptions exist.
- When you flag a smell, name it and propose the specific refactoring(s) listed for it. Apply refactorings in the order given (numbered = sequence, bulleted = standalone alternatives).
- Prefer the "let it crash" philosophy, pattern matching, and small composable functions over defensive branching.
- Smells are grouped: **Traditional** (classic OO smells that still apply), **Design-related** (Elixir-specific, architectural), and **Low-level** (Elixir-specific, local/implementation).

---

## Traditional code smells (apply to Elixir)

**Comments** — Comments compensating for unclear code. → Extract function (name it after the comment); Extract expressions; Extract constant (for magic numbers); Rename identifier; replace type comments with `@spec`/`@type`/`@typedoc`.

**Divergent change** — One module changes for many unrelated reasons. → Module decomposition (split large module, then rename); Move definition to a more suitable module; Behaviour extraction.

**Duplicated code** — Same logic in multiple places. → Extract function / Extract expressions; Fold against a function definition; Generalise a function definition (higher-order); Turn anonymous into local functions; Merge multiple definitions; Move expression out of `case`; Static structure reuse; `Introduce import`; Defining a subset of a Map (`Map.take/2`); Modifying keys in a Map; Reducing a boolean equality expression (use `in`).

**Feature envy** — A function uses another module's data/functions more than its own. → Extract to outside (extract function, then move definition to the envied module); Remove `import` attributes to surface the true origin first.

**Inappropriate intimacy** — Modules depend on each other's internals; closures capturing outer scope. → Closure conversion (impure → pure anonymous fn) + fix leftover params via Add/remove a parameter; Move definition; Module decomposition.

**Large class (large module)** — A module doing the work of several. → Module decomposition (split + rename); Behaviour extraction; Move definition.

**Long function** — Function too long to reason about. → Extract function; Transform nested `if` into `cond`; Fold against a function definition; Remove dead code; Introduce pattern matching over a parameter (multi-clause); Replace pipeline with a function / Pipeline using `with`; `Default value for an absent key in a Map` (`Map.get/3`); Defining a subset of a Map (`Map.take/2`); Remove nested conditional statements; Splitting a definition.

**Long parameter list** — Too many parameters. → Add/remove a parameter (drop unused); Reorder parameters; Introduce parameter struct (group into tuple, then tuple → struct).

**Primitive obsession** — Primitives standing in for richer abstractions. → Introduce parameter struct (tuple → struct); Add type declarations and contracts.

**Shotgun surgery** — One change forces edits across many modules. → Move definition to consolidate related logic into cohesive modules (create one if none fits).

**Speculative generality** — Unused flexibility built for hypothetical futures. → Inline function; Inline macro; Add/remove a parameter (drop unused); Rename identifier (concrete names); Behaviour inlining; Remove dead code; Eliminate single branch.

**Switch statements** — Duplicated conditional sequences switching on a type code. → Replace conditional with polymorphism via Protocols; Introduce pattern matching over a parameter (multi-clause); Introduce overloading; or Extract-to-outside → Generalise (higher-order) → Fold to dedupe.

---

## Design-related Elixir-specific smells

**Agent obsession** — Agent-interaction logic spread across the system. → Generalise a function definition (centralise) → Move definition → Add/remove a parameter; optionally Behaviour extraction to define a contract for all Agent access.

**Code organization by process** — A process (e.g. GenServer) used where plain modules/functions would do, forcing concurrency on clients. → Remove processes → Remove dead code (drop now-unused callbacks).

**Compile-time global configuration** — Module attributes set from `Application` env at compile time, blocking runtime config. → Extract constant (inline); Introduce temporary duplicate (use `Application.compile_env/3`); Fold against a function definition; Remove dead code.

**Complex extractions in clauses** — Pattern matching in a multi-clause signature extracts values used in *both* guards and body. → Simplify pattern matching with nested structs (match only outermost); Convert guards to conditionals (consolidate to one clause, extract in body); Equality guard to pattern matching; Struct guard to matching; Remove unnecessary calls to `length/1`; Function-clauses-to-`case`-clauses.

**Data manipulation by Migration** — An `Ecto.Migration` module doing both schema and data changes. → Module decomposition (split data updates into a new module + rename) → Extract-to-outside (extract function, move to new module) → Remove dead code; optionally Simplify Ecto schema field validation; Pipeline for database transactions (`Ecto.Multi`).

**GenServer envy** — Using `Task`/`Agent` but handling them like a `GenServer`. → Generalise a process abstraction (→ GenServer) → Introduce processes (remove bottlenecks) → Register a process → Remove dead code.

**Large code generation by macros** — Macros expanding to lots of code, hurting compile/runtime. → Extract-to-outside: extract the bulky part into a regular function the macro calls → Move definition for cohesion.

**Large messages** — Sending more data between processes than needed. → Defining a subset of a Map (send only needed fields); Extract expressions (store the one needed value in a temp var before `spawn`); optionally Add a tag to messages.

**Unrelated multi-clause function** — One multi-clause function mixing unrelated business rules behind many guards/patterns. → Rename identifier (split into separate same-named groups); Function-clauses-to-`case`-clauses; Move definition (relocate clauses that don't belong); plus guard simplifications (Struct guard to matching, Equality guard to pattern matching, Simplify guard sequences, Convert guards to conditionals, Simplify nested-struct matching, Remove unnecessary `length/1`).

**Unsupervised process** — Processes created outside a supervision tree. → Move error-handling mechanisms to supervision trees (delegate start to a Supervisor / Application); Move definition (move `start` calls into a Supervisor).

**Untested polymorphic behaviors** — Polymorphic functions whose supported types aren't covered/documented. → Introduce overloading (→ multi-clause per type) → Fold against a function definition; Typing parameters and return values (document supported types).

**"Use" instead of "import"** — `use` declaring a dependency where `import`/`alias` suffices (tight coupling). → Introduce `import` → Remove dead code (drop `use`); optionally Alias expansion; Remove `import` attributes.

**Using App Configuration for libraries** — A library function configured via global `Application` env instead of arguments, limiting reuse. → Explicit a changed function signature: Add an optional `Keyword` list parameter (default preserves current behaviour) → Type the new parameter.

**Using exceptions for control-flow** — A library forcing clients to handle control-flow exceptions. → Rename identifier (add trailing `!`) → Introduce temporary duplicate (non-bang variant returning `{:ok, _}`/`{:error, _}`) → Fold so the bang version builds on the non-raising one. Alternatively Introduce processes + Move error-handling to supervision trees ("let it crash").

---

## Low-level Elixir-specific smells

**Accessing non-existent map/struct fields** — Dynamic field access where missing vs `nil` is ambiguous. → Default value for an absent key in a Map; Introduce pattern matching over a parameter (extract field for guards); Simplify checks via truthiness; Explicit double boolean negation; Struct field access elimination (temp var) → Equality guard to pattern matching.

**Alternative return types** — A param (e.g. a `Keyword` list) drastically changes the return type. → Introduce temporary duplicate (one copy per return type) → Rename each → Explicit changed signature (Add/remove a parameter to drop the opts; Type params & returns) → Remove dead code.

**Complex branching** — A function handling many error types in one branchy block. → Extract function (one private fn per branch); Introduce pattern matching over a parameter (multi-clause per error type).

**Complex else clauses in `with`** — A `with` flattening all error handling into one big `else`. → Extract function (one private fn per error) → Remove dead code (drop the `else`); optionally Remove redundant last clause in `with`; Move `with` clauses without pattern matching.

**Dynamic atom creation** — Creating atoms from untrusted/dynamic input (`String.to_atom/1`); atoms aren't GC'd and are capped. → Extract function (explicit string→atom conversion with guarded branches) → Introduce pattern matching over a parameter (multi-clause); or Fold against an existing converter; or Gradual change (swap to `String.to_existing_atom/1` then remove old line).

**Modules with identical names** — Name clashes / unloadable modules; libraries not namespacing. → Rename identifier (adopt `LibraryName.ModuleName` namespace); Gradual change (duplicate under new name, deprecate old, later Remove dead code); Move file (relocate + rename).

**Speculative assumptions** — Defensive/imprecise code returning unplanned values instead of crashing. → Introduce pattern matching over a parameter (force a crash on unexpected input); Pipeline using `with`.

**Unnecessary macros** — Macros where plain functions/structs would do. → Inline macro; or Extract-to-outside (extract the function-able part out of the macro) → Move definition.

**Working with invalid data** — A (library) function not validating its parameters, surfacing confusing deep errors. → Typing parameters and return values; Add type declarations and contracts; Introduce pattern matching over a parameter; Struct guard to matching; Simplify guard sequences; Convert guards to conditionals. Validate at boundaries, close to the end-user.

---

## Notes

- "Composite" refactorings (e.g. Module decomposition, Extract-to-outside, Introduce parameter struct, Explicit a changed function signature, Gradual change) are themselves sequences of smaller refactorings — apply their sub-steps in order.
- Many low-level smells specifically affect **library authors** (Using App Configuration for libraries, Using exceptions for control-flow, Working with invalid data, Modules with identical names) — weigh public-API impact and breaking changes before applying.
- Full descriptions, code examples, and the complete refactoring catalog (Functional, Elixir-specific, Erlang-specific, Traditional) are in the source repos linked at the top.
