# Phase 7.55 - Plain English Architecture

Updated: 2026-04-12
Owner: Codex architecture
Status: Active companion explainer

## What This Doc Is

This is the plain-English version of the app architecture.

If `docs/contracts/phase_7_55_architecture_contract.md` is the hard contract, this doc
is the "how the whole restaurant loop works" explanation.

## The Short Version

The app works like this:

1. source systems send in real restaurant facts
2. the app cleans those into one shared truth shape
3. the app locks standards for 60 days
4. the app builds a weekly plan from those standards plus rolling demand
5. the app compares live operations against that plan
6. closed shifts become frozen history
7. Learn teaches from repeated closed results, not from live guesswork

## The Big Idea

There are three different things the app has to keep separate:

1. what "good" looks like
2. how much business is expected
3. what actually happened

If those get blurred together, the screens may still look nice but the product
starts quietly lying.

So we keep them separate on purpose.

## What Comes In From Outside

### POS

POS tells us things like:

- sales
- covers
- checks / tickets
- when a shift is really closed

### Labor system

Labor tells us things like:

- schedules
- punches
- worked hours
- labor dollars

In the real world, some labor systems do not give clean labor dollars right at
close time. When that happens, the app is allowed to use the sanctioned wage
setup the restaurant has chosen so operations can keep moving.

### Reservation system

Reservations tell us things like:

- how many people are on the books
- when they are booked for
- whether they are still active, canceled, or changed

## What The App Does First

The app does not let each outside system talk to the screens in its own
language.

Instead, it turns everything into one internal shape:

**canonical operational facts**

That just means:

- one shared app version of shift truth
- one shared app version of open/live truth
- one shared app version of reservation-book truth

So later, Shift, Variance, History, and Learn are all reading the same kind of
facts instead of each surface inventing its own.

## Benchmark: Setting The Standard

Benchmark looks backward at closed history and says:

- what does good usually look like here
- what target CPLH / SPLH / PPA should we run
- what wage standards are in force
- what OPZ range should we use

Benchmark is not the weekly plan.

It is the standard-setting layer.

The app locks that into a 60-day `TargetCycle`.

That means:

- targets should not drift every day
- a manager gets one override per cycle
- admin can replace with provenance
- if nobody overrides, the app can roll into the next recommended cycle at the
  boundary
- a new cycle changes future comparison context
- a new cycle does not rewrite old history

Wages have one extra practical rule:

- if labor integration provides usable wage truth, use that
- if it does not, the admin wage mix in Settings is the sanctioned
  manual fallback
- that manual wage setup is supposed to have the same downstream effect
  as integrated wage truth on Benchmark / Schedule / Shift / Variance
- if a vendor later sends richer finalized labor truth after close, we may need
  explicit sync/reconciliation handlers around close and other boundary events
  instead of assuming the first close-time ingest is the last word forever
  targets

### What the Benchmark range badges mean

The CPLH range bar is trying to answer one simple question:

**do we have a clean, coachable working range yet?**

There are two versions of that answer.

#### When a manager is choosing star shifts

- `OPZ RANGE TOO NARROW`
  - math:
    - fewer than 2 selected star shifts, or
    - the selected CPLH spread is under `0.15`
  - hospitality meaning:
    - the chosen shifts are too similar to teach from yet

- `OPZ RANGE TOO WIDE`
  - math:
    - the selected CPLH spread is over `1.25`
  - hospitality meaning:
    - the chosen shifts are describing too many different service patterns

- `GOOD OPZ RANGE`
  - math:
    - the selected spread sits between those bounds
  - hospitality meaning:
    - the selected shifts describe a realistic service rhythm the team can
      repeat

#### When the app is recommending the benchmark

- `RANGE UNCONFIRMED`
  - math:
    - the recommendation summary is missing, or
    - the recommendation path marked the evidence as insufficient
  - hospitality meaning:
    - we do not have enough recent clean history to coach to this yet

- `RANGE TOO WIDE TO TEACH`
  - math:
    - the persisted benchmark summary says the range quality is too wide
  - hospitality meaning:
    - lunch, dinner, and late night are behaving too differently for one
      combined range to teach cleanly

- `RANGE UNCERTAIN`
  - math:
    - the persisted benchmark summary says the range quality is too narrow /
      weak
  - hospitality meaning:
    - we have some history, but not a stable enough pattern to call this a
      dependable benchmark yet

- `GOOD OPZ RANGE`
  - math:
    - the persisted summary is present and not in the weak / wide /
      insufficient branches
  - hospitality meaning:
    - the recent shift history is strong enough to use this as a real working
      benchmark

## Demand: Estimating Volume

Demand is a different question.

Demand is not:

- what good looks like

Demand is:

- how much business we think is coming

Right now the intended shape is:

- 60-day baseline
- fixed 3-week recent trend
- later, reservation-book signal layered in

Reservations help here because they make the forecast smarter.

They do not become the benchmark standard by themselves.

## Plan: Turning Standards + Demand Into A Week

Once we know:

- the standard we want to run
- and the business we expect

the app builds the operating plan.

That is what `SchedulePlan` is doing.

It answers:

- forecast covers
- forecast sales
- required FOH / BOH hours
- labor dollars / labor percent projections
- daily allocation
- later service-period allocation

Then the app locks the week into a `WeeklyPlanSnapshot`.

That matters because otherwise the week would keep changing while we are trying
to judge performance against it.

In other words:

- forecast logic can keep improving before the week locks
- once the week is in force, the app auto-locks that weekly comparison plan
- the app can notify the manager that a new week plan is now active

So the weekly snapshot is the answer to:

what plan was actually in force for this week?

## Time: What Anchors Everything

Time is not based on random device clocks.

The master anchor is:

- restaurant-local timezone
- restaurant business date

That controls:

- when the day rolls
- what day 1 of the week is
- when WTD resets
- when a weekly plan locks
- when a 60-day cycle starts and ends
- how service periods are defined

For the deep timing rules, see:

- `docs/contracts/phase_7_55_time_boundary_contract.md`

## Shift: What Is Happening Right Now

Shift is the live operational screen.

It should answer:

- how are we doing right now
- are we ahead or behind today
- what matters first operationally

Shift lives in "now."

That means it can use live open-shift context.

But it should not pretend that live context is already closed historical
truth.

So the clean rule is:

- Shift truth = live facts
- compared against benchmark-backed standards
- and today's plan context

Also:

- Shift's default view is whole-day
- Phase 10.5 adds a daypart-aware view alongside the whole-day view without
  replacing it

## Variance: Comparing Plan To What Happened

Variance is where things get a little more mixed.

It has to show:

- closed truth
- open in-progress context
- projected remaining context

That is useful, but only if it is honest about what each row is.

So the real rule is:

- closed rows are final truth
- open rows are live in-progress context
- projected rows are plan / forecast context

They should not all sound equally final.

Variance is still downstream of Benchmark and Plan.

That means:

- it compares closed/open/projected truth in the right category
- against the locked weekly plan
- and against benchmark-backed standards where those standards are the
  comparison rule

## History: Frozen Truth

History is where already-closed reality goes.

History should answer:

- what actually happened in that closed week
- which target cycle was active then
- which weekly plan was in force then
- what patterns repeated

The key rule:

history does not get rewritten by a later benchmark cycle

If a new 60-day target goes live next month, last month's closed shifts stay
graded in the context they actually closed under.

That keeps history trustworthy.

So History truth is:

- closed facts
- compared in the week/cycle context that was active when they closed

## Learn: Teaching From Closed Reality

Learn is not supposed to teach from live rows, open rows, or projections.

Learn should teach from two things:

1. the current benchmark set
2. repeated evidence from closed history

So Learn should help answer:

- what standard are we coaching to now
- what leaks keep repeating
- what wins keep repeating
- what should the manager protect or fix next

Good Learn teaching needs:

- sample count
- metric proof
- repeated pattern evidence
- source examples
- cycle / time provenance

That is why Learn is downstream of History, not a second live dashboard.

So Learn truth is:

- repeated closed evidence
- interpreted against benchmark context
- without pretending open/projected rows are part of the evidence

## What Changes On Which Cadence

### Every 60 days

- the target cycle
- benchmark-backed standards
- manager override eligibility

### Every week

- the weekly plan snapshot
- the week-in-force comparison plan

### During the day

- open shift context
- reservation-book context
- the live Shift screen

### Only when a shift really closes

- closed actual truth
- WTD closed facts
- History
- Learn evidence

## What Must Never Happen

These are the big "do not cheat" rules:

- do not let weekly forecast changes rewrite the locked weekly snapshot
- do not let new target cycles rewrite old closed history
- do not let open rows masquerade as closed truth
- do not let widgets invent their own source-of-truth rules
- do not let Learn teach from guesses that have not closed yet

## The Product In One Plain-English Flow

```text
Source systems tell us what happened.
The app cleans that into one truth shape.
Benchmark sets the standard for 60 days.
Demand estimates how much business is coming.
Plan turns those into the week's operating targets.
Shift shows how today is moving right now.
Variance compares the week against the locked plan.
History stores what really closed.
Learn teaches what keeps repeating.
```

## The Most Important Mental Model

If someone asks "what is this screen really for?", the answer should be:

- Benchmark = set the standard
- Plan = decide the week
- Shift = manage right now
- Variance = compare plan vs actual
- History = preserve what closed
- Learn = teach from repeated closed results

That is the architecture in plain English.
